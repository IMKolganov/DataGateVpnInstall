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
: "${TCP_VPN_SUBNET:?TCP_VPN_SUBNET required in site.env}"
# Always derive from TCP subnet — do not trust stale PIHOLE_DNS_IP left in copied site.env.example
PIHOLE_DNS_IP="${TCP_VPN_SUBNET%.*}.1"
: "${TCP_API_PORT:=5011}"
: "${UDP_API_PORT:=5010}"
: "${PIHOLE_WEB_PORT:=8080}"

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
    if ufw status 2>/dev/null | grep -q "${XRAY_DNS_IDENTITY_SUBNET}"; then
      pass "UFW mentions identity subnet $XRAY_DNS_IDENTITY_SUBNET"
    else
      fail "UFW missing identity subnet $XRAY_DNS_IDENTITY_SUBNET (DNS from sendThrough)"
    fi
  fi

  xray_api_conf="$INSTALL_HOME/nginx-docker/nginx/conf.d/xray-api.conf"
  if [[ -f "$xray_api_conf" ]] && grep -q 'proxy_set_header Authorization' "$xray_api_conf"; then
    pass "xray-api.conf proxies Authorization"
  else
    fail "xray-api.conf missing Authorization (dashboard JWT → 401)"
  fi

  xray_env="$INSTALL_HOME/datagate-monitor-xray/.env"
  if [[ -f "$xray_env" ]]; then
    base="$(grep -E '^XRAY_PIHOLE_BASE_URL=' "$xray_env" | cut -d= -f2-)"
    expect="http://${PIHOLE_DNS_IP}:8080"
    if [[ "$base" == "$expect" || "$base" == "http://${PIHOLE_DNS_IP}:${PIHOLE_WEB_PORT:-8080}" ]]; then
      pass "Xray Pi-hole Base URL matches TCP .1 ($base)"
    else
      fail "Xray Pi-hole Base URL stale/wrong (got $base want http://${PIHOLE_DNS_IP}:8080)"
    fi

    # render-config.sh skips the xHTTP inbound instead of failing the container (so a broken extra
    # transport can never kill :443). That makes a missing inbound silent — assert it here.
    xhttp_enabled="$(grep -E '^XRAY_XHTTP_ENABLED=' "$xray_env" | cut -d= -f2- || true)"
    if is_true "${xhttp_enabled:-false}"; then
      xhttp_port="$(grep -E '^XRAY_XHTTP_PORT=' "$xray_env" | cut -d= -f2- || true)"
      xhttp_port="${xhttp_port:-2053}"
      if [[ ! "$xhttp_port" =~ ^[0-9]+$ ]]; then
        fail "XRAY_XHTTP_PORT is not numeric in $xray_env (got: $xhttp_port)"
      else
        xray_cfg="$INSTALL_HOME/datagate-monitor-xray/data/xray_data/xray/config.json"
        if [[ -r "$xray_cfg" ]] && command -v jq >/dev/null 2>&1; then
          if jq -e --argjson p "$xhttp_port" \
            'any(.inbounds[]?; .port == $p and .streamSettings.network == "xhttp")' \
            "$xray_cfg" >/dev/null 2>&1; then
            pass "xHTTP inbound rendered on :$xhttp_port"
          else
            fail "XRAY_XHTTP_ENABLED=true but no xHTTP inbound on :$xhttp_port — docker logs datagate-monitor-xray shows why it was skipped"
          fi
        else
          warn "cannot read $xray_cfg — skipped the xHTTP inbound assertion"
        fi

        if command -v ss >/dev/null 2>&1; then
          if ss -lnt 2>/dev/null | grep -qE "[:.]${xhttp_port}[[:space:]]"; then
            pass "xHTTP port :$xhttp_port is listening"
          else
            fail "nothing listening on :$xhttp_port — check compose port publish and the inbound"
          fi
        fi
      fi
    fi

    # Which transport issued profiles point at. Profiles are re-rendered on download, so this decides
    # what every client of this node gets on its next connect.
    link_transport="$(grep -E '^XRAY_CLIENT_LINK_TRANSPORT=' "$xray_env" | cut -d= -f2- || true)"
    link_transport="${link_transport:-primary}"
    case "$link_transport" in
      primary)
        pass "client profiles point at the primary inbound"
        ;;
      xhttp)
        if is_true "${xhttp_enabled:-false}"; then
          pass "client profiles point at the xHTTP inbound"
        else
          fail "XRAY_CLIENT_LINK_TRANSPORT=xhttp but XRAY_XHTTP_ENABLED is not true — clients would get a dead profile"
        fi
        ;;
      *)
        fail "XRAY_CLIENT_LINK_TRANSPORT must be primary or xhttp (got: $link_transport)"
        ;;
    esac
  fi
fi

echo
if [[ "$FAILS" -eq 0 ]]; then
  echo "=== POST-INSTALL OK — no hel-class gaps detected ==="
  exit 0
fi
echo "=== POST-INSTALL FAILED ($FAILS) — fix before registering in dashboard ==="
exit 1
