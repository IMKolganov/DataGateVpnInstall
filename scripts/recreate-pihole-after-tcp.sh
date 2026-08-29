#!/usr/bin/env bash
# Recreate Pi-hole after openvpn-tcp-wss is up.
#
# Why: pi-hole uses network_mode: container:openvpn-tcp-wss. Docker stores the
# peer as a container ID. After host reboot / compose recreate of TCP OpenVPN,
# that ID is gone → datagate-pihole Exited (128) "No such container".
# force-recreate re-joins the *current* openvpn-tcp-wss netns.
#
# Usage:
#   sudo ./recreate-pihole-after-tcp.sh
#   INSTALL_HOME=/home/imkolganov sudo -E ./recreate-pihole-after-tcp.sh
#
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

if [[ -n "${ENV_FILE:-}" && -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

: "${INSTALL_HOME:=${HOME}}"
# Prefer site.env next to stacks when systemd only sets ENV_FILE=site.env
if [[ -f "${INSTALL_HOME}/site.env" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${INSTALL_HOME}/site.env"
  set +a
elif [[ -f "${INSTALL_HOME}/site.env.installed" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${INSTALL_HOME}/site.env.installed"
  set +a
fi

PIHOLE_DIR="${INSTALL_HOME}/pi-hole"
TCP_NAME=openvpn-tcp-wss
PIHOLE_NAME=datagate-pihole
WAIT_TCP_SEC="${WAIT_TCP_SEC:-180}"
WAIT_PIHOLE_SEC="${WAIT_PIHOLE_SEC:-120}"

[[ -d "$PIHOLE_DIR" ]] || die "missing $PIHOLE_DIR"
command -v docker >/dev/null || die "docker not found"

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
      docker logs "$name" 2>&1 | tail -20 || true
      die "$name is $st"
    fi
    sleep 1
  done
  die "$name not healthy after ${budget}s (last=$st)"
}

wait_container_running "$TCP_NAME" "$WAIT_TCP_SEC"
# Prefer healthy TCP when healthcheck exists
tcp_h="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$TCP_NAME" 2>/dev/null || echo none)"
if [[ "$tcp_h" != "none" ]]; then
  wait_healthy_or_running "$TCP_NAME" 60 || true
fi

info "force-recreate $PIHOLE_NAME (re-join $TCP_NAME netns)"
(cd "$PIHOLE_DIR" && docker compose up -d --force-recreate)

wait_healthy_or_running "$PIHOLE_NAME" "$WAIT_PIHOLE_SEC"

DNS_IP="$(ip -4 -br addr show tun-tcp 2>/dev/null | awk '{print $3}' | cut -d/ -f1 || true)"
if [[ -n "$DNS_IP" ]] && command -v dig >/dev/null; then
  info "probe dig @$DNS_IP youtube.com"
  if dig @"$DNS_IP" youtube.com +time=3 +tries=2 +short | head -3; then
    echo "OK  DNS responds on $DNS_IP"
  else
    echo "WARN dig @$DNS_IP failed — FTL may still be warming; check: docker logs $PIHOLE_NAME"
  fi
fi

info "done"
