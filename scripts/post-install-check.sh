#!/usr/bin/env bash
# Post-install checks for a DataGate VPN host — fail if the hel-class gaps are still wrong.
# Usage (as root, after install-vpn-host.sh):
#   ENV_FILE=~/site.env ./scripts/post-install-check.sh
#   # or: INSTALL_HOME=/home/user ./scripts/post-install-check.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
die() { echo "ERROR: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; FAILS=$((FAILS + 1)); }
warn() { echo "WARN: $*" >&2; }
FAILS=0

ENV_FILE="${ENV_FILE:-}"
if [[ -z "$ENV_FILE" ]]; then
  for c in \
    "${INSTALL_HOME:-}/site.env" \
    "$SCRIPT_DIR/../site.env" \
    "${HOME}/site.env"; do
    [[ -f "$c" ]] && ENV_FILE="$c" && break
  done
fi
[[ -n "$ENV_FILE" && -f "$ENV_FILE" ]] || die "set ENV_FILE to site.env (or INSTALL_HOME)"

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

: "${INSTALL_HOME:?INSTALL_HOME required in site.env}"
: "${PIHOLE_DNS_IP:=${TCP_VPN_SUBNET%.*}.1}"
: "${TCP_API_PORT:=5011}"
: "${UDP_API_PORT:=5010}"

echo "=== post-install check ($INSTALL_HOME) ==="

# OpenVPN containers
for name in openvpn-tcp-wss openvpn-udp-wss; do
  if docker inspect --format '{{.State.Running}}' "$name" 2>/dev/null | grep -q true; then
    pass "$name running"
  else
    fail "$name not running"
  fi
done

# Cipher + DCO via manager API
for port in "$TCP_API_PORT" "$UDP_API_PORT"; do
  label="api:$port"
  json="$(curl -fsS --max-time 5 "http://127.0.0.1:${port}/api/info" 2>/dev/null || true)"
  if [[ -z "$json" ]]; then
    fail "$label /api/info unreachable"
    continue
  fi
  echo "$json" | grep -q '"dco":"true"' && pass "$label dco=true" || fail "$label dco not true"
  if echo "$json" | grep -qE '"cipher":"(AES-128-GCM|CHACHA20-POLY1305|AES-256-GCM)"'; then
    pass "$label AEAD cipher present"
  else
    fail "$label cipher missing/legacy (want AES-GCM or ChaCha)"
  fi
  # Prefer AES when host has AES-NI
  if grep -qw aes /proc/cpuinfo 2>/dev/null; then
    if echo "$json" | grep -q '"cipher":"AES-128-GCM"'; then
      pass "$label AES-128-GCM (AES-NI host)"
    else
      warn "$label cipher is not AES-128-GCM but host has AES-NI — check .env CIPHER"
    fi
  fi
done

# DCO kernel module
if lsmod 2>/dev/null | awk '{print $1}' | grep -qE '^ovpn'; then
  pass "kernel ovpn/dco module loaded"
else
  warn "no ovpn module in lsmod — DCO may be userspace-only"
fi

# Compose has CIPHER wired
for stack in openvpn-tcp-wss openvpn-udp-wss; do
  yml="$INSTALL_HOME/$stack/docker-compose.yml"
  if [[ -f "$yml" ]] && grep -q 'CIPHER:' "$yml"; then
    pass "$stack compose has CIPHER"
  else
    fail "$stack compose missing CIPHER env"
  fi
done

is_true() {
  case "${1:-}" in
    true|TRUE|yes|YES|1|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

if is_true "${INSTALL_XRAY:-false}"; then
  : "${XRAY_DNS_IDENTITY_SUBNET:?XRAY_DNS_IDENTITY_SUBNET required}"
  if docker inspect --format '{{.State.Running}}' datagate-monitor-xray 2>/dev/null | grep -q true; then
    pass "datagate-monitor-xray running"
  else
    fail "datagate-monitor-xray not running"
  fi

  iface="$(grep -E '^XRAY_DNS_IDENTITY_IFACE=' "$INSTALL_HOME/datagate-monitor-xray/.env" 2>/dev/null | cut -d= -f2- || true)"
  if [[ "$iface" == "eth0" ]]; then
    pass "XRAY_DNS_IDENTITY_IFACE=eth0"
  else
    fail "XRAY_DNS_IDENTITY_IFACE must be eth0 (got: ${iface:-empty})"
  fi

  if ip route | grep -q "${XRAY_DNS_IDENTITY_SUBNET%/*}"; then
    pass "host route for identity subnet"
  else
    fail "missing host route for $XRAY_DNS_IDENTITY_SUBNET — systemctl start datagate-xray-dns-route"
  fi

  if systemctl is-enabled datagate-xray-dns-route.service >/dev/null 2>&1; then
    pass "datagate-xray-dns-route.service enabled"
  else
    fail "datagate-xray-dns-route.service not enabled"
  fi

  if [[ -f "$INSTALL_HOME/host/.env" ]] && grep -q 'XRAY_DNS_IDENTITY_SUBNET=' "$INSTALL_HOME/host/.env"; then
    pass "host/.env has identity subnet (UFW)"
  else
    fail "host/.env missing XRAY_DNS_IDENTITY_SUBNET"
  fi

  if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q "$PIHOLE_DNS_IP.*53"; then
      pass "UFW mentions Pi-hole :53"
    else
      warn "UFW status did not show $PIHOLE_DNS_IP:53 — verify identity DNS rules"
    fi
  fi
fi

echo
if [[ "$FAILS" -eq 0 ]]; then
  echo "=== POST-INSTALL OK — no hel-class gaps detected ==="
  exit 0
fi
echo "=== POST-INSTALL FAILED ($FAILS) — fix before registering in dashboard ==="
exit 1
