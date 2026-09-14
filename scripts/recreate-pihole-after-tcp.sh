#!/usr/bin/env bash
# Recreate Pi-hole after openvpn-tcp-wss is up (idempotent).
#
# Why: pi-hole uses network_mode: container:openvpn-tcp-wss. Docker stores the
# peer as a container ID. After host reboot / compose recreate of TCP OpenVPN,
# that ID is gone → datagate-pihole Exited (128) "No such container".
# force-recreate re-joins the *current* openvpn-tcp-wss netns.
#
# Usage:
#   sudo ./recreate-pihole-after-tcp.sh
#   INSTALL_HOME=/home/imkolganov sudo -E ./recreate-pihole-after-tcp.sh
#   FORCE_RECREATE=1 sudo ./recreate-pihole-after-tcp.sh   # skip idempotent check
#
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

# systemd / caller sets INSTALL_HOME (and optional TCP_TUN_DEV) — site.env must not override
LOCKED_INSTALL_HOME="${INSTALL_HOME:-}"
LOCKED_TCP_TUN_DEV="${TCP_TUN_DEV:-}"

source_env_file() {
  local f="$1"
  [[ -f "$f" ]] || return 0
  set -a
  # shellcheck disable=SC1090
  source "$f"
  set +a
  if [[ -n "$LOCKED_INSTALL_HOME" ]]; then
    INSTALL_HOME="$LOCKED_INSTALL_HOME"
    export INSTALL_HOME
  fi
  if [[ -n "$LOCKED_TCP_TUN_DEV" ]]; then
    TCP_TUN_DEV="$LOCKED_TCP_TUN_DEV"
    export TCP_TUN_DEV
  fi
}

if [[ -n "${ENV_FILE:-}" && -f "$ENV_FILE" ]]; then
  source_env_file "$ENV_FILE"
fi

: "${INSTALL_HOME:=${HOME}}"
if [[ -n "$LOCKED_INSTALL_HOME" ]]; then
  INSTALL_HOME="$LOCKED_INSTALL_HOME"
  export INSTALL_HOME
fi

if [[ -f "${INSTALL_HOME}/site.env" ]]; then
  source_env_file "${INSTALL_HOME}/site.env"
elif [[ -f "${INSTALL_HOME}/site.env.installed" ]]; then
  source_env_file "${INSTALL_HOME}/site.env.installed"
fi

# Final lock (site.env may have redefined INSTALL_HOME again)
if [[ -n "$LOCKED_INSTALL_HOME" ]]; then
  INSTALL_HOME="$LOCKED_INSTALL_HOME"
  export INSTALL_HOME
fi
if [[ -n "$LOCKED_TCP_TUN_DEV" ]]; then
  TCP_TUN_DEV="$LOCKED_TCP_TUN_DEV"
  export TCP_TUN_DEV
fi

PIHOLE_DIR="${INSTALL_HOME}/pi-hole"
TCP_NAME=openvpn-tcp-wss
PIHOLE_NAME=datagate-pihole
TCP_TUN_DEV="${TCP_TUN_DEV:-tun-tcp}"
[[ "$TCP_TUN_DEV" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,15}$ ]] \
  || die "unsafe TCP_TUN_DEV='$TCP_TUN_DEV' (expected e.g. tun-tcp)"
WAIT_TCP_SEC="${WAIT_TCP_SEC:-180}"
WAIT_PIHOLE_SEC="${WAIT_PIHOLE_SEC:-180}"
WAIT_DNS_SEC="${WAIT_DNS_SEC:-90}"
FORCE_RECREATE="${FORCE_RECREATE:-0}"
mkdir -p "${INSTALL_HOME}/host"
LOCK_FILE="${LOCK_FILE:-${INSTALL_HOME}/host/.pihole-after-tcp.lock}"

[[ -d "$PIHOLE_DIR" ]] || die "missing $PIHOLE_DIR"
command -v docker >/dev/null || die "docker not found"

# Avoid overlapping boot + docker-events recreate
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  info "another recreate is running — waiting for lock"
  flock 9
fi

wait_container_running() {
  local name="$1" budget="$2" i st
  info "waiting for $name running (up to ${budget}s)"
  for ((i = 0; i < budget; i++)); do
    st="$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null || echo false)"
    if [[ "$st" == "true" ]]; then
      echo "OK  $name running"
      return 0
    fi
    sleep 1
  done
  die "$name not running after ${budget}s"
}

wait_healthy_or_running() {
  local name="$1" budget="$2" i st
  info "waiting for $name healthy (up to ${budget}s)"
  for ((i = 0; i < budget; i++)); do
    st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null || echo missing)"
    if [[ "$st" == "healthy" || "$st" == "running" ]]; then
      echo "OK  $name $st"
      return 0
    fi
    if [[ "$st" == "exited" || "$st" == "dead" ]]; then
      docker logs "$name" 2>&1 | tail -30 || true
      die "$name is $st"
    fi
    sleep 1
  done
  die "$name not healthy after ${budget}s (last=$st)"
}

pihole_joined_to_current_tcp() {
  local tcp_id mode short
  tcp_id="$(docker inspect -f '{{.Id}}' "$TCP_NAME" 2>/dev/null || true)"
  [[ -n "$tcp_id" ]] || return 1
  mode="$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$PIHOLE_NAME" 2>/dev/null || echo missing)"
  short="${tcp_id:0:12}"
  [[ "$mode" == "container:${tcp_id}" || "$mode" == "container:${short}" ]]
}

pihole_ok_now() {
  local st err
  st="$(docker inspect -f '{{.State.Status}}' "$PIHOLE_NAME" 2>/dev/null || echo missing)"
  err="$(docker inspect -f '{{.State.Error}}' "$PIHOLE_NAME" 2>/dev/null || true)"
  [[ "$st" == "running" ]] || return 1
  [[ "$err" != *No\ such\ container* ]] || return 1
  pihole_joined_to_current_tcp
}

wait_container_running "$TCP_NAME" "$WAIT_TCP_SEC"
tcp_h="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$TCP_NAME" 2>/dev/null || echo none)"
if [[ "$tcp_h" != "none" && "$tcp_h" != "healthy" ]]; then
  wait_healthy_or_running "$TCP_NAME" 90 || true
fi

if [[ "$FORCE_RECREATE" != "1" ]] && pihole_ok_now; then
  info "$PIHOLE_NAME already running and joined to current $TCP_NAME — skip force-recreate"
else
  info "force-recreate $PIHOLE_NAME (re-join $TCP_NAME netns)"
  (cd "$PIHOLE_DIR" && docker compose up -d --force-recreate)
fi

wait_healthy_or_running "$PIHOLE_NAME" "$WAIT_PIHOLE_SEC"
pihole_joined_to_current_tcp || die "$PIHOLE_NAME NetworkMode is not the current $TCP_NAME container"

# Prefer live tunnel IP; fall back to site.env / subnet .1
DNS_IP="$(ip -4 -br addr show "$TCP_TUN_DEV" 2>/dev/null | awk '{print $3}' | cut -d/ -f1 || true)"
if [[ -z "$DNS_IP" ]]; then
  DNS_IP="${PIHOLE_DNS_IP:-}"
fi
if [[ -z "$DNS_IP" && -n "${TCP_VPN_SUBNET:-}" ]]; then
  DNS_IP="${TCP_VPN_SUBNET%.*}.1"
fi

if [[ -n "$DNS_IP" ]] && command -v dig >/dev/null; then
  info "probe dig @$DNS_IP youtube.com (up to ${WAIT_DNS_SEC}s — FTL may import history)"
  dns_ok=0
  for ((i = 0; i < WAIT_DNS_SEC; i += 3)); do
    if dig @"$DNS_IP" youtube.com +time=2 +tries=1 +short 2>/dev/null | grep -qE '^[0-9.]+$'; then
      dig @"$DNS_IP" youtube.com +time=2 +tries=1 +short | head -3
      echo "OK  DNS responds on $DNS_IP"
      dns_ok=1
      break
    fi
    sleep 3
  done
  if [[ "$dns_ok" -ne 1 ]]; then
    warn "dig @$DNS_IP still failing after ${WAIT_DNS_SEC}s — check: docker logs $PIHOLE_NAME"
  fi
fi

info "done"
