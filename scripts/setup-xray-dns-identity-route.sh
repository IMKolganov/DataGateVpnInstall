#!/usr/bin/env bash
# Host route so Pi-hole (on tun .1) can reach Xray per-client identity IPs (10.80.x.x).
# Without this, DNS replies to identity sources blackhole and clients get DNS errors.
#
# Usage:
#   sudo ENV_FILE=~/DataGateVpnInstall/site.env ./scripts/setup-xray-dns-identity-route.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "ERROR: $*" >&2; exit 1; }

ENV_FILE="${ENV_FILE:-}"
if [[ -z "$ENV_FILE" ]]; then
  for candidate in \
    "$SCRIPT_DIR/../site.env" \
    "${INSTALL_HOME:-}/site.env" \
    "$HOME/DataGateVpnInstall/site.env"; do
    if [[ -f "$candidate" ]]; then
      ENV_FILE="$candidate"
      break
    fi
  done
fi
[[ -n "$ENV_FILE" && -f "$ENV_FILE" ]] || die "set ENV_FILE to site.env"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

[[ "$(id -u)" -eq 0 ]] || die "run as root"

: "${XRAY_DNS_IDENTITY_SUBNET:?XRAY_DNS_IDENTITY_SUBNET required}"

if [[ ! "$XRAY_DNS_IDENTITY_SUBNET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
  die "XRAY_DNS_IDENTITY_SUBNET must look like 10.80.1.0/24 (got: $XRAY_DNS_IDENTITY_SUBNET)"
fi

CONTAINER="${XRAY_CONTAINER_NAME:-datagate-monitor-xray}"

wait_for_container_ip() {
  local i=0 max_wait="${XRAY_DNS_ROUTE_WAIT_SECS:-90}"
  while [[ "$i" -lt "$max_wait" ]]; do
    if docker inspect "$CONTAINER" >/dev/null 2>&1; then
      container_ip="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$CONTAINER")"
      if [[ -n "$container_ip" ]]; then
        return 0
      fi
    fi
    sleep 2
    i=$((i + 2))
  done
  return 1
}

if ! wait_for_container_ip; then
  echo "[xray-dns-route] ERROR: container $CONTAINER not ready within ${XRAY_DNS_ROUTE_WAIT_SECS:-90}s" >&2
  exit 1
fi

net_name="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$CONTAINER")"
bridge_dev="$(docker network inspect "$net_name" -f '{{if .Options}}{{index .Options "com.docker.network.bridge.name"}}{{end}}' 2>/dev/null || true)"
if [[ -z "$bridge_dev" ]]; then
  bridge_dev="$(ip route get "$container_ip" 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") { print $(i + 1); exit }}')"
fi
[[ -n "$bridge_dev" ]] || bridge_dev="docker0"

echo "[xray-dns-route] route $XRAY_DNS_IDENTITY_SUBNET via $container_ip dev $bridge_dev (container $CONTAINER)"
ip route replace "$XRAY_DNS_IDENTITY_SUBNET" via "$container_ip" dev "$bridge_dev"
