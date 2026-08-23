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

echo "=== [7/7] stale site.env Xray Pi-hole fields sync to new subnets ==="
stale="$TEST_ROOT/site.env.stale"
cp "$TEST_ROOT/site.env" "$stale"
# Simulate operator who changed VPN subnets but left example Xray DNS lines
sed -i \
  -e 's/TCP_VPN_SUBNET=10.51.40.0/TCP_VPN_SUBNET=10.51.52.0/' \
  -e 's/UDP_VPN_SUBNET=10.51.42.0/UDP_VPN_SUBNET=10.51.54.0/' \
  -e 's|XRAY_DNS_IDENTITY_SUBNET=10.80.5.0/24|XRAY_DNS_IDENTITY_SUBNET=10.80.4.0/24|' \
  "$stale"
# Inject stale (wrong) values that used to stick
{
  echo 'XRAY_DNS1=10.51.40.1'
  echo 'XRAY_DNS2=10.51.40.1'
  echo 'XRAY_PIHOLE_BASE_URL=http://10.51.40.1:8080'
  echo 'XRAY_PIHOLE_CLIENT_SUBNET_PREFIX=10.80.1.'
  echo 'XRAY_PIHOLE_EXCLUDE_PREFIXES=10.51.40.,10.51.42.'
  echo 'XRAY_DNS_IDENTITY_IFACE=ens3'
} >>"$stale"
sed -i "s|INSTALL_HOME=.*|INSTALL_HOME=${TEST_ROOT}/home-stale|" "$stale"
"$ROOT/scripts/install-vpn-host.sh" --render-only --env "$stale"
xenv="$TEST_ROOT/home-stale/datagate-monitor-xray/.env"
grep -q 'XRAY_PIHOLE_BASE_URL=http://10.51.52.1:8080' "$xenv" \
  && pass "stale Base URL rewritten to TCP .1" || fail "stale Base URL not rewritten ($(grep PIHOLE_BASE "$xenv" || true))"
grep -q 'XRAY_DNS1=10.51.52.1' "$xenv" \
  && pass "stale DNS1 rewritten" || fail "stale DNS1 not rewritten"
grep -q 'XRAY_PIHOLE_CLIENT_SUBNET_PREFIX=10.80.4.' "$xenv" \
  && pass "stale identity prefix rewritten" || fail "stale prefix not rewritten"
grep -q 'XRAY_PIHOLE_EXCLUDE_PREFIXES=10.51.52.,10.51.54.' "$xenv" \
  && pass "stale excludes rewritten" || fail "stale excludes not rewritten"
grep -q 'XRAY_DNS_IDENTITY_IFACE=eth0' "$xenv" \
  && pass "WAN iface ens3 forced to eth0" || fail "iface not forced to eth0"

# Placeholder XRAY_API_ALLOW_IPS must die early
bad_allow="$TEST_ROOT/site.env.bad-allow"
cp "$TEST_ROOT/site.env" "$bad_allow"
sed -i "s|INSTALL_HOME=.*|INSTALL_HOME=${TEST_ROOT}/home-bad-allow|" "$bad_allow"
echo 'XRAY_API_ALLOW_IPS=YOUR_DASHBOARD_PUBLIC_IP' >>"$bad_allow"
if "$ROOT/scripts/install-vpn-host.sh" --render-only --env "$bad_allow" 2>/dev/null; then
  fail "should reject YOUR_* in XRAY_API_ALLOW_IPS"
else
  pass "rejects placeholder XRAY_API_ALLOW_IPS"
fi

echo "=== [8/10] critical path guards (xray net labels, SSH IP under sudo, post-install DNS) ==="
INSTALLER="$ROOT/scripts/install-vpn-host.sh"
POST="$ROOT/scripts/post-install-check.sh"

grep -q 'com.docker.compose.network=xray_network' "$INSTALLER" \
  && pass "ensure_xray_network sets compose network label" \
  || fail "ensure_xray_network missing compose labels"

grep -q 'ss -Htn state established' "$INSTALLER" \
  && pass "detect_ssh_client_ip recovers session after sudo env_reset" \
  || fail "detect_ssh_client_ip missing ss fallback"

# Stale PIHOLE_DNS_IP in site.env must not win over TCP_VPN_SUBNET (post-install false FAIL)
TCP_VPN_SUBNET=10.51.52.0
PIHOLE_DNS_IP=10.51.40.1
# shellcheck disable=SC2034
PIHOLE_DNS_IP="${TCP_VPN_SUBNET%.*}.1"
if [[ "$PIHOLE_DNS_IP" == "10.51.52.1" ]] \
  && grep -q 'PIHOLE_DNS_IP="${TCP_VPN_SUBNET%.*}.1"' "$POST"; then
  pass "post-install forces PIHOLE_DNS_IP from TCP_VPN_SUBNET"
else
  fail "post-install PIHOLE_DNS_IP not forced from TCP subnet"
fi

echo "=== [9/10] docker network label recreate (if docker available) ==="
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  n="datagate-verify-xray-net-$$"
  docker network rm "$n" >/dev/null 2>&1 || true
  docker network create "$n" >/dev/null
  # Mimic ensure_xray_network: unlabeled → rm → create with labels
  label="$(docker network inspect -f '{{index .Labels "com.docker.compose.network"}}' "$n" 2>/dev/null || true)"
  if [[ "$label" == "xray_network" ]]; then
    fail "unexpected: unlabeled create already had compose label"
  else
    docker network rm "$n" >/dev/null
    docker network create \
      --label com.docker.compose.project=datagate-monitor-xray \
      --label com.docker.compose.network=xray_network \
      "$n" >/dev/null
    label="$(docker network inspect -f '{{index .Labels "com.docker.compose.network"}}' "$n")"
    docker network rm "$n" >/dev/null
    if [[ "$label" == "xray_network" ]]; then
      pass "docker network recreate with compose labels works"
    else
      fail "labeled network missing com.docker.compose.network=$label"
    fi
  fi
else
  echo "SKIP: docker network label test (docker not available)"
fi

echo "=== [10/10] xHTTP extra inbound (render-config.sh) ==="
xenv_xhttp="$home/datagate-monitor-xray/.env"
if grep -q '^XRAY_XHTTP_ENABLED=true' "$xenv_xhttp" \
  && grep -q '^XRAY_XHTTP_PORT=2053' "$xenv_xhttp"; then
  pass "xray .env enables xHTTP inbound"
else
  fail "xray .env missing XRAY_XHTTP_* ($(grep XHTTP "$xenv_xhttp" || true))"
fi

# UFW must know about the same port the container publishes.
if grep -q '^EXTRA_TCP_PORT=2053' "$home/host/.env"; then
  pass "host/.env opens the xHTTP port for UFW"
else
  fail "host/.env EXTRA_TCP_PORT does not match XRAY_XHTTP_PORT ($(grep EXTRA_TCP_PORT "$home/host/.env" || true))"
fi

# render-config.sh lives in the xray repo — absent when DataGateVpnInstall is checked out alone.
RENDER="$ROOT/../../xray/scripts/xray/render-config.sh"
if [[ -f "$RENDER" ]] && command -v jq >/dev/null 2>&1; then
  xd="$TEST_ROOT/xray-render"
  rm -rf "$xd"
  mkdir -p "$xd"
  # Contents do not matter: without the xray binary validate_config only checks structure.
  : >"$xd/fullchain.pem"
  : >"$xd/privkey.pem"
  cfg="$xd/config.json"
  render_env=(env
    CONFIG_PATH="$cfg" ACCESS_LOG="$xd/access.log" ERROR_LOG="$xd/error.log"
    PORT=443 DNS1=1.1.1.1 DNS2=8.8.8.8
    XRAY_MGMT_HOST=127.0.0.1 XRAY_MGMT_PORT=10085 INBOUND_TAG=vless-in
    XRAY_TRANSPORT_MODE=tls XRAY_ACCEPT_PROXY_PROTOCOL=true
    XRAY_TLS_CERT_FILE="$xd/fullchain.pem" XRAY_TLS_KEY_FILE="$xd/privkey.pem")
  vless_count() { jq '[.inbounds[] | select(.protocol == "vless")] | length' "$cfg"; }

  "${render_env[@]}" XRAY_XHTTP_ENABLED=false bash "$RENDER" >/dev/null
  [[ "$(vless_count)" == "1" ]] \
    && pass "disabled xHTTP leaves a single VLESS inbound" \
    || fail "disabled xHTTP changed the inbound count ($(vless_count))"

  "${render_env[@]}" XRAY_XHTTP_ENABLED=true XRAY_XHTTP_PORT=2053 XRAY_XHTTP_PATH=/api/v1/update bash "$RENDER" >/dev/null
  if [[ "$(vless_count)" == "2" ]] \
    && [[ "$(jq -r '.inbounds[] | select(.tag == "vless-xhttp-in") | .streamSettings.network' "$cfg")" == "xhttp" ]] \
    && [[ "$(jq -r '.inbounds[] | select(.tag == "vless-xhttp-in") | .streamSettings.security' "$cfg")" == "tls" ]] \
    && [[ "$(jq -r '.inbounds[] | select(.tag == "vless-xhttp-in") | .streamSettings.xhttpSettings.path' "$cfg")" == "/api/v1/update" ]] \
    && [[ "$(jq -r '.inbounds[] | select(.tag == "vless-xhttp-in") | .port' "$cfg")" == "2053" ]]; then
    pass "xHTTP inbound rendered next to the primary one"
  else
    fail "xHTTP inbound missing or malformed ($(jq -c '[.inbounds[].tag]' "$cfg"))"
  fi

  # Reached directly, so PROXY protocol must stay off — otherwise every client handshake fails.
  [[ "$(jq -r '.inbounds[] | select(.tag == "vless-xhttp-in") | .streamSettings.sockopt.acceptProxyProtocol // false' "$cfg")" == "false" ]] \
    && pass "xHTTP inbound has no acceptProxyProtocol" \
    || fail "xHTTP inbound got acceptProxyProtocol (nginx is not in front of it)"

  # The primary inbound must survive the patch untouched.
  [[ "$(jq -r '.inbounds[] | select(.tag == "vless-in") | .streamSettings.sockopt.acceptProxyProtocol' "$cfg")" == "true" ]] \
    && pass "primary inbound keeps acceptProxyProtocol" \
    || fail "primary inbound lost acceptProxyProtocol"

  "${render_env[@]}" XRAY_XHTTP_ENABLED=true XRAY_XHTTP_PORT=443 bash "$RENDER" >/dev/null 2>&1
  [[ "$(vless_count)" == "1" ]] \
    && pass "port collision with the primary inbound is skipped" \
    || fail "xHTTP inbound was added on the primary port"

  "${render_env[@]}" XRAY_XHTTP_ENABLED=true XRAY_XHTTP_PORT=2053 XRAY_TLS_CERT_FILE="$xd/missing.pem" bash "$RENDER" >/dev/null 2>&1
  [[ "$(vless_count)" == "1" ]] \
    && pass "missing certificate skips the xHTTP inbound" \
    || fail "xHTTP inbound was added without a certificate"
else
  echo "SKIP: render-config.sh checks (xray repo or jq not available)"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== ALL VERIFY CHECKS PASSED ==="
else
  echo "=== VERIFY CHECKS FAILED ==="
  exit 1
fi
