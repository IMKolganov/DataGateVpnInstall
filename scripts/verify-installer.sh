#!/usr/bin/env bash
# Local verification plan for install/vpns (no root, no full docker stack).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="/tmp/datagate-vpn-install-verify"
FAIL=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; FAIL=1; }

echo "=== [0/7] smoke-test-ssh-scenarios.sh ==="
"$ROOT/scripts/smoke-test-ssh-scenarios.sh"

echo "=== [1/7] smoke-test-local.sh ==="
"$ROOT/scripts/smoke-test-local.sh"

echo "=== [2/7] render xray stack + host/.env fields ==="
rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT"
cat >"$TEST_ROOT/site.env" <<EOF
PUBLIC_IP=203.0.113.50
WAN_IF=eth0
INSTALL_HOME=${TEST_ROOT}/home
CERTBOT_EMAIL=test@datagateapp.com
UDP_WSS_DOMAIN=s1-v.datagateapp.com
TCP_WSS_DOMAIN=s4-v.datagateapp.com
BACKEND__BASEURL=https://api.datagateapp.com/
DASHBOARD_API_IP=81.27.110.243
ADMIN_SSH_IP=164.215.15.224
DOCKER_BRIDGE_CIDR=172.17.0.0/16
TCP_VPN_SUBNET=10.51.40.0
UDP_VPN_SUBNET=10.51.42.0
PIHOLE_WEBPASSWORD=test-secret
INSTALL_DOCKER=false
SETUP_UFW=false
ISSUE_CERTS=false
START_STACKS=false
INSTALL_XRAY=true
XRAY_DOMAIN=xs-v.datagateapp.com
XRAY_DNS_IDENTITY_SUBNET=10.80.5.0/24
XRAY_API_ALLOW_IPS=81.27.110.243
NGINX_CERTBOT_CONF=${TEST_ROOT}/home/nginx-docker/certbot/conf
EOF

"$ROOT/scripts/install-vpn-host.sh" --render-only --env "$TEST_ROOT/site.env"

home="$TEST_ROOT/home"
for key in TCP_VPN_SUBNET UDP_VPN_SUBNET PIHOLE_DNS_IP XRAY_DNS_IDENTITY_SUBNET XRAY_API_HTTPS_PORT; do
  if grep -q "^${key}=" "$home/host/.env"; then
    pass "host/.env has $key"
  else
    fail "host/.env missing $key"
  fi
done

if grep -q '10.80.5.0/24' "$home/site.env" && [[ -f "$home/site.env" ]]; then
  pass "site.env present with identity subnet"
else
  fail "site.env missing or wrong identity subnet"
fi

echo "=== [3/7] route script rejects bad subnet ==="
cat >"$TEST_ROOT/site.env.bad" <<EOF
XRAY_DNS_IDENTITY_SUBNET=not-a-subnet
EOF
if ENV_FILE="$TEST_ROOT/site.env.bad" "$ROOT/scripts/setup-xray-dns-identity-route.sh" 2>/dev/null; then
  fail "route script should reject bad subnet"
else
  pass "route script rejects bad subnet"
fi

echo "=== [4/7] route script fails when xray container absent ==="
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  if sudo -n true 2>/dev/null; then
    if sudo ENV_FILE="$TEST_ROOT/site.env" XRAY_DNS_ROUTE_WAIT_SECS=4 \
      "$home/host/setup-xray-dns-identity-route.sh" 2>/dev/null; then
      fail "route script should fail when xray container absent"
    else
      pass "route script fails when xray container absent"
    fi
  else
  if ENV_FILE="$TEST_ROOT/site.env" XRAY_DNS_ROUTE_WAIT_SECS=4 \
    "$home/host/setup-xray-dns-identity-route.sh" 2>/dev/null; then
    fail "route script should fail without root/container"
  else
    pass "route script fails without root or container (expected)"
  fi
  fi
else
  echo "SKIP: route container test (docker not available)"
fi

echo "=== [5/7] systemd unit valid ==="
unit="$home/host/datagate-xray-dns-route.service"
if grep -qE '__[A-Z0-9_]+__' "$unit"; then
  fail "placeholders in systemd unit"
else
  pass "systemd unit placeholders resolved"
fi
if command -v systemd-analyze >/dev/null 2>&1; then
  if systemd-analyze verify "$unit" 2>/dev/null; then
    pass "systemd-analyze verify unit"
  else
    fail "systemd-analyze verify unit"
  fi
fi

echo "=== [6/7] load_env rejects overlapping identity subnet ==="
overlap_env="$TEST_ROOT/site.env.overlap"
cp "$TEST_ROOT/site.env" "$overlap_env"
sed -i 's/XRAY_DNS_IDENTITY_SUBNET=10.80.5.0\/24/XRAY_DNS_IDENTITY_SUBNET=10.51.40.0\/24/' "$overlap_env"
if "$ROOT/scripts/install-vpn-host.sh" --render-only --env "$overlap_env" 2>/dev/null; then
  fail "should reject identity subnet overlapping TCP VPN subnet"
else
  pass "rejects identity subnet overlapping TCP VPN subnet"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== ALL VERIFY CHECKS PASSED ==="
else
  echo "=== VERIFY CHECKS FAILED ==="
  exit 1
fi
