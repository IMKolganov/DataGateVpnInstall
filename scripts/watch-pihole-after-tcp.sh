#!/usr/bin/env bash
# Keep Pi-hole joined to the *current* openvpn-tcp-wss container.
#
# 1) On start: run recreate once (covers reboot — TCP may come up after docker.service).
# 2) Then follow docker events for openvpn-tcp-wss start (covers compose recreate / pull).
#
# Installed as datagate-pihole-after-tcp.service (Type=simple, Restart=always).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECREATE="${SCRIPT_DIR}/recreate-pihole-after-tcp.sh"
TCP_NAME=openvpn-tcp-wss

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

[[ -x "$RECREATE" ]] || die "missing executable $RECREATE"
command -v docker >/dev/null || die "docker not found"

run_recreate() {
  local reason="$1"
  info "recreate Pi-hole ($reason)"
  if ! "$RECREATE"; then
    warn "recreate failed ($reason) — will retry on next TCP start / systemd restart"
    return 1
  fi
}

# Boot / service start
run_recreate "service start" || true

info "watching docker events for ${TCP_NAME} start"
# --since 0s avoids a huge backlog of historical events after long uptime.
# Docker Engine 29+ events templates use Actor.ID (plain .ID → exit 64 USAGE).
docker events \
  --since 0s \
  --filter "name=${TCP_NAME}" \
  --filter "event=start" \
  --format '{{.Time}} {{.Actor.ID}}' \
  | while read -r _ts _id; do
      # brief settle so compose healthchecks / tun device can appear
      sleep 2
      run_recreate "docker event: ${TCP_NAME} start" || true
    done

# docker events exiting is fatal — systemd Restart=always will respawn
die "docker events stream ended"
