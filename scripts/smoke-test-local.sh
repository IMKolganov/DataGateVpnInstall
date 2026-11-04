#!/usr/bin/env bash
# Local smoke test for install/vpns (no root, no OpenVPN pull).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="/tmp/datagate-vpn-install-test"
ENV_NO_XRAY="$TEST_ROOT/site.env.no-xray"
ENV_XRAY="$TEST_ROOT/site.env.xray"
RENDER_NO_XRAY="$TEST_ROOT/render-no-xray"
RENDER_XRAY="$TEST_ROOT/render-xray"
RENDER_UDP_ONLY="$TEST_ROOT/render-udp-only"
RENDER_TCP_ONLY="$TEST_ROOT/render-tcp-only"
RENDER_XRAY_ONLY="$TEST_ROOT/render-xray-only"
FAIL=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; FAIL=1; }

write_test_env() {
  local dest="$1" install_home="$2" with_xray="$3" with_udp="${4:-true}" with_tcp="${5:-true}"
  cat >"$dest" <<EOF
INSTALL_OPENVPN_UDP=${with_udp}
INSTALL_OPENVPN_TCP=${with_tcp}
PUBLIC_IP=203.0.113.50
WAN_IF=eth0
INSTALL_HOME=${install_home}
CERTBOT_EMAIL=test@datagateapp.com
UDP_WSS_DOMAIN=s1-test.datagateapp.com
TCP_WSS_DOMAIN=s4-test.datagateapp.com
HFS_DOMAIN=
BACKEND__BASEURL=https://api.datagateapp.com/
DASHBOARD_API_IP=81.27.110.243
ADMIN_SSH_IP=164.215.15.224
PROMETHEUS_IP=
NODE_EXPORTER_PORT=9100
DOCKER_BRIDGE_CIDR=172.17.0.0/16
TCP_VPN_SUBNET=10.51.40.0
UDP_VPN_SUBNET=10.51.42.0
TCP_DNS1=10.51.40.1
TCP_DNS2=10.51.40.1
UDP_DNS1=10.51.40.1
UDP_DNS2=10.51.40.1
PIHOLE_DNS_IP=10.51.40.1
TCP_PORT=1297
UDP_PORT=1194
TCP_API_PORT=5011
UDP_API_PORT=5010
TCP_MANAGEMENT_PORT=5097
UDP_MANAGEMENT_PORT=5096
TCP_TUN_DEV=tun-tcp
UDP_TUN_DEV=ovpn-udp
UDP_WAN_IF=eth0
PIHOLE_WEBPASSWORD=test-pihole-secret
PIHOLE_WEB_PORT=8080
TZ=UTC
ASPNETCORE_ENVIRONMENT=Production
TCP_DCO=true
UDP_DCO=true
TCP_CIPHER=AES-128-GCM
TCP_DATA_CIPHERS=AES-128-GCM:CHACHA20-POLY1305
UDP_CIPHER=AES-128-GCM
UDP_DATA_CIPHERS=AES-128-GCM:CHACHA20-POLY1305
TCP_VPN_NETMASK=255.255.255.0
UDP_VPN_NETMASK=255.255.255.0
INSTALL_DOCKER=false
SETUP_UFW=false
ISSUE_CERTS=false
START_STACKS=false
INSTALL_XRAY=${with_xray}
EOF
  if [[ "$with_xray" == true ]]; then
    cat >>"$dest" <<EOF
XRAY_DOMAIN=xs2-test.datagateapp.com
XRAY_MANAGER_HOST_PORT=5012
XRAY_API_HTTPS_PORT=9443
XRAY_API_ALLOW_IPS=81.27.110.243,94.237.4.29
XRAY_TRANSPORT_MODE=tls
XRAY_ACCEPT_PROXY_PROTOCOL=true
XRAY_XHTTP_ENABLED=true
XRAY_XHTTP_PORT=2053
XRAY_XHTTP_PATH=/api/v1/update
XRAY_XHTTP_MODE=auto
XRAY_CLIENT_LINK_TRANSPORT=xhttp
XRAY_HOST_GATEWAY=172.17.0.1
XRAY_DNS1=10.51.40.1
XRAY_DNS2=10.51.40.1
XRAY_PIHOLE_BASE_URL=http://10.51.40.1:8080
XRAY_DNS_IDENTITY_ENABLED=true
XRAY_DNS_IDENTITY_SUBNET=10.80.1.0/24
XRAY_DNS_IDENTITY_IFACE=eth0
XRAY_PIHOLE_CLIENT_SUBNET_PREFIX=10.80.1.
XRAY_PIHOLE_EXCLUDE_PREFIXES=10.51.40.,10.51.42.
NGINX_CERTBOT_CONF=${install_home}/nginx-docker/certbot/conf
EOF
  fi
}

render() {
  "$ROOT/scripts/install-vpn-host.sh" --render-only --env "$1"
}

check_no_placeholders() {
  local dir="$1"
  if grep -rE '__[A-Z0-9_]+__|YOUR_|example\.com|CHANGE_ME' "$dir" \
    --include='*.conf' --include='*.sh' --include='*.env' --include='docker-compose.yml' 2>/dev/null; then
    fail "placeholders remain in $dir"
  else
    pass "no placeholders in $dir"
  fi
}

make_dummy_certs() {
  local cert_root="$1"
  shift
  local d
  for d in "$@"; do
    local live="$cert_root/live/$d"
    mkdir -p "$live"
    openssl req -x509 -nodes -newkey rsa:2048 -days 1 \
      -keyout "$live/privkey.pem" \
      -out "$live/fullchain.pem" \
      -subj "/CN=$d" 2>/dev/null
  done
}

write_full_nginx_for_home() {
  local home="$1"
  (
    set --
    # shellcheck disable=SC1091
    source "$ROOT/scripts/install-vpn-host.sh"
    set -a
    # shellcheck disable=SC1090
    source "$home/site.env.installed"
    set +a
    INSTALL_HOME="$home"
    write_full_nginx "$home/nginx-docker/nginx/conf.d" "$home/nginx-docker/nginx/stream.d"
  )
}

nginx_test() {
  local home="$1" label="$2" network="${3:-}"
  local net_args=()
  if [[ -n "$network" ]]; then
    docker network create "$network" 2>/dev/null || true
    docker rm -f datagate-monitor-xray 2>/dev/null || true
    docker run -d --name datagate-monitor-xray --network "$network" alpine sleep 600 >/dev/null
    net_args=(--network "$network")
  fi
  if docker run --rm "${net_args[@]}" \
    --add-host=host.docker.internal:host-gateway \
    -v "$home/nginx-docker/nginx/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$home/nginx-docker/nginx/conf.d:/etc/nginx/conf.d:ro" \
    -v "$home/nginx-docker/nginx/stream.d:/etc/nginx/stream.d:ro" \
    -v "$home/nginx-docker/certbot/conf:/etc/letsencrypt:ro" \
    nginx:stable nginx -t 2>&1 | tee "/tmp/nginx-test-${label}.log" | grep -q 'test is successful'; then
    pass "nginx -t $label"
  else
    fail "nginx -t $label"
    cat "/tmp/nginx-test-${label}.log" >&2
  fi
  if [[ -n "$network" ]]; then
    docker rm -f datagate-monitor-xray >/dev/null 2>&1 || true
  fi
}

check_xray_host_assets() {
  local home="$1"
  if [[ -x "$home/host/setup-xray-dns-identity-route.sh" ]]; then
    pass "xray route script"
  else
    fail "xray route script missing"
  fi
  if [[ -f "$home/host/datagate-xray-dns-route.service" ]]; then
    pass "xray route systemd unit rendered"
  else
    fail "xray route systemd unit missing"
  fi
  if grep -qE '__[A-Z0-9_]+__' "$home/host/datagate-xray-dns-route.service" 2>/dev/null; then
    fail "placeholders in datagate-xray-dns-route.service"
  else
    pass "xray route unit placeholders resolved"
  fi
  if grep -q 'XRAY_DNS_IDENTITY_SUBNET=' "$home/host/.env"; then
    pass "host/.env has identity subnet"
  else
    fail "host/.env missing identity subnet"
  fi
  if [[ -f "$home/site.env" ]]; then
    pass "site.env copied"
  else
    fail "site.env missing"
  fi
  if grep -q 'ExecStart=.*/host/setup-xray-dns-identity-route.sh' "$home/host/datagate-xray-dns-route.service"; then
    pass "systemd ExecStart points to host script"
  else
    fail "systemd ExecStart wrong"
  fi
}

compose_config() {
  local dir="$1" name="$2"
  if (cd "$dir" && docker compose --env-file .env config -q 2>/dev/null); then
    pass "docker compose config $name"
  else
    (cd "$dir" && docker compose --env-file .env config) || fail "docker compose config $name"
  fi
}

rm -rf "$TEST_ROOT"
mkdir -p "$TEST_ROOT"

write_test_env "$ENV_NO_XRAY" "$RENDER_NO_XRAY" false
write_test_env "$ENV_XRAY" "$RENDER_XRAY" true

echo "=== render OpenVPN-only ==="
render "$ENV_NO_XRAY"
check_no_placeholders "$RENDER_NO_XRAY"

echo "=== render OpenVPN + Xray ==="
render "$ENV_XRAY"
check_no_placeholders "$RENDER_XRAY"
check_xray_host_assets "$RENDER_XRAY"

echo "=== render single-protocol hosts ==="
write_test_env "$TEST_ROOT/site.env.udp-only" "$RENDER_UDP_ONLY" false true false
write_test_env "$TEST_ROOT/site.env.tcp-only" "$RENDER_TCP_ONLY" false false true
write_test_env "$TEST_ROOT/site.env.xray-only" "$RENDER_XRAY_ONLY" true false false
sed -i '/^UDP_WSS_DOMAIN=/d; /^TCP_WSS_DOMAIN=/d' "$TEST_ROOT/site.env.xray-only"
render "$TEST_ROOT/site.env.udp-only"
render "$TEST_ROOT/site.env.tcp-only"
render "$TEST_ROOT/site.env.xray-only"
for home in "$RENDER_UDP_ONLY" "$RENDER_TCP_ONLY" "$RENDER_XRAY_ONLY"; do
  check_no_placeholders "$home"
done
[[ -d "$RENDER_UDP_ONLY/openvpn-udp-wss" && ! -e "$RENDER_UDP_ONLY/openvpn-tcp-wss" ]] \
  && pass "udp-only renders only the UDP stack" || fail "udp-only stack dirs wrong"
[[ -d "$RENDER_TCP_ONLY/openvpn-tcp-wss" && ! -e "$RENDER_TCP_ONLY/openvpn-udp-wss" ]] \
  && pass "tcp-only renders only the TCP stack" || fail "tcp-only stack dirs wrong"
[[ -d "$RENDER_XRAY_ONLY/datagate-monitor-xray" && ! -e "$RENDER_XRAY_ONLY/openvpn-tcp-wss" \
  && ! -e "$RENDER_XRAY_ONLY/openvpn-udp-wss" ]] \
  && pass "xray-only renders no OpenVPN stack" || fail "xray-only stack dirs wrong"
for home in "$RENDER_UDP_ONLY" "$RENDER_XRAY_ONLY"; do
  label="$(basename "$home")"
  grep -q '^    network_mode: host$' "$home/pi-hole/docker-compose.yml" \
    && pass "pihole host netns ($label)" || fail "pihole netns not host ($label)"
  grep -q 'ip addr replace 10.51.40.1/32 dev dg-dns' "$home/host/datagate-dns-dummy.service" \
    && pass "dummy DNS unit holds TCP .1 ($label)" || fail "dummy DNS unit wrong ($label)"
  [[ ! -e "$home/host/datagate-pihole-after-tcp.service" ]] \
    && pass "no pihole-after-tcp unit ($label)" || fail "pihole-after-tcp unit rendered without TCP ($label)"
done
grep -q '^PIHOLE_DNS_INTERFACE=dg-dns,ovpn-udp$' "$RENDER_UDP_ONLY/pi-hole/.env" \
  && pass "udp-only Pi-hole on dg-dns + UDP tun" || fail "udp-only PIHOLE_DNS_INTERFACE wrong"
grep -q '^PIHOLE_DNS_INTERFACE=dg-dns$' "$RENDER_XRAY_ONLY/pi-hole/.env" \
  && pass "xray-only Pi-hole on dg-dns" || fail "xray-only PIHOLE_DNS_INTERFACE wrong"
grep -q '^PIHOLE_DNS_INTERFACE=tun-tcp$' "$RENDER_TCP_ONLY/pi-hole/.env" \
  && pass "tcp-only Pi-hole on TCP tun" || fail "tcp-only PIHOLE_DNS_INTERFACE wrong"
grep -q 'network_mode: "container:openvpn-tcp-wss"' "$RENDER_TCP_ONLY/pi-hole/docker-compose.yml" \
  && pass "tcp-only pihole joins TCP netns" || fail "tcp-only pihole netns"
grep -q '^OPENVPN_TCP=false$' "$RENDER_UDP_ONLY/host/.env" && grep -q '^OPENVPN_UDP=true$' "$RENDER_UDP_ONLY/host/.env" \
  && pass "udp-only host/.env stack flags" || fail "udp-only host/.env stack flags"
grep -q 'server_name s1-test.datagateapp.com xs2-test.datagateapp.com;' "$RENDER_XRAY_ONLY/nginx-docker/nginx/conf.d/00-acme.conf" \
  && fail "xray-only ACME lists WSS domains" || pass "xray-only ACME has no WSS domains"
grep -q 'server_name xs2-test.datagateapp.com;' "$RENDER_XRAY_ONLY/nginx-docker/nginx/conf.d/00-acme.conf" \
  && pass "xray-only ACME serves the Xray domain" || fail "xray-only ACME server_name wrong"
if ( INSTALL_OPENVPN_UDP=false INSTALL_OPENVPN_TCP=false INSTALL_XRAY=false; \
  sed 's/^INSTALL_OPENVPN_UDP=.*/INSTALL_OPENVPN_UDP=false/; s/^INSTALL_OPENVPN_TCP=.*/INSTALL_OPENVPN_TCP=false/' \
    "$ENV_NO_XRAY" >"$TEST_ROOT/site.env.none"; render "$TEST_ROOT/site.env.none" ) >/dev/null 2>&1; then
  fail "installer should refuse a host with no protocol"
else
  pass "installer refuses a host with no protocol"
fi

echo "=== nginx -t UDP-only / TCP-only / Xray-only ==="
make_dummy_certs "$RENDER_UDP_ONLY/nginx-docker/certbot/conf" s1-test.datagateapp.com
write_full_nginx_for_home "$RENDER_UDP_ONLY"
[[ -f "$RENDER_UDP_ONLY/nginx-docker/nginx/conf.d/udp-wss.conf" && ! -e "$RENDER_UDP_ONLY/nginx-docker/nginx/conf.d/tcp-wss.conf" ]] \
  && pass "udp-only nginx has only udp-wss.conf" || fail "udp-only nginx confs wrong"
nginx_test "$RENDER_UDP_ONLY" udp-only
make_dummy_certs "$RENDER_TCP_ONLY/nginx-docker/certbot/conf" s4-test.datagateapp.com
write_full_nginx_for_home "$RENDER_TCP_ONLY"
nginx_test "$RENDER_TCP_ONLY" tcp-only
make_dummy_certs "$RENDER_XRAY_ONLY/nginx-docker/certbot/conf" xs2-test.datagateapp.com
write_full_nginx_for_home "$RENDER_XRAY_ONLY"
[[ ! -e "$RENDER_XRAY_ONLY/nginx-docker/nginx/conf.d/udp-wss.conf" && ! -e "$RENDER_XRAY_ONLY/nginx-docker/nginx/conf.d/tcp-wss.conf" ]] \
  && pass "xray-only nginx has no WSS confs" || fail "xray-only nginx still has WSS confs"
nginx_test "$RENDER_XRAY_ONLY" xray-only datagate-monitor-xray_xray_network
compose_config "$RENDER_UDP_ONLY/pi-hole" pihole-udp-only
compose_config "$RENDER_XRAY_ONLY/pi-hole" pihole-xray-only

echo "=== nginx -t OpenVPN-only ==="
make_dummy_certs "$RENDER_NO_XRAY/nginx-docker/certbot/conf" \
  s1-test.datagateapp.com s4-test.datagateapp.com
write_full_nginx_for_home "$RENDER_NO_XRAY"
nginx_test "$RENDER_NO_XRAY" openvpn-only

echo "=== nginx -t with Xray ==="
make_dummy_certs "$RENDER_XRAY/nginx-docker/certbot/conf" \
  s1-test.datagateapp.com s4-test.datagateapp.com xs2-test.datagateapp.com
write_full_nginx_for_home "$RENDER_XRAY"
nginx_test "$RENDER_XRAY" xray-stack datagate-monitor-xray_xray_network

echo "=== docker compose config ==="
compose_config "$RENDER_NO_XRAY/openvpn-tcp-wss" openvpn-tcp
compose_config "$RENDER_NO_XRAY/openvpn-udp-wss" openvpn-udp
compose_config "$RENDER_NO_XRAY/pi-hole" pihole
compose_config "$RENDER_NO_XRAY/nginx-docker" nginx-no-xray
compose_config "$RENDER_XRAY/datagate-monitor-xray" xray
compose_config "$RENDER_XRAY/nginx-docker" nginx-xray

echo "=== nginx FD / worker limits ==="
for home in "$RENDER_NO_XRAY" "$RENDER_XRAY"; do
  label="$(basename "$home")"
  nginx_conf="$home/nginx-docker/nginx/nginx.conf"
  nginx_compose="$home/nginx-docker/docker-compose.yml"
  grep -qE 'worker_rlimit_nofile[[:space:]]+65535' "$nginx_conf" \
    && pass "worker_rlimit_nofile 65535 ($label)" \
    || fail "worker_rlimit_nofile 65535 missing ($label)"
  grep -qE 'worker_connections[[:space:]]+16384' "$nginx_conf" \
    && pass "worker_connections 16384 ($label)" \
    || fail "worker_connections 16384 missing ($label)"
  if grep -qE 'worker_connections[[:space:]]+1024' "$nginx_conf"; then
    fail "old worker_connections 1024 still present ($label)"
  else
    pass "no worker_connections 1024 ($label)"
  fi
  if awk '
    $1=="ulimits:" {u=1}
    u && $1=="nofile:" {n=1}
    n && $1=="soft:" && $2=="65535" {s=1}
    n && $1=="hard:" && $2=="65535" {h=1}
    END { exit (s && h) ? 0 : 1 }
  ' "$nginx_compose"; then
    pass "compose ulimits.nofile 65535 ($label)"
  else
    fail "compose ulimits.nofile 65535 missing ($label)"
  fi
done

grep -q 'datagate-monitor-xray:443' "$RENDER_XRAY/nginx-docker/nginx/stream.d/sni-xray.conf" \
  && pass "stream → xray" || fail "stream xray upstream"
grep -q 'host.docker.internal:5010' "$RENDER_NO_XRAY/nginx-docker/nginx/conf.d/udp-wss.conf" \
  && pass "udp wss upstream" || fail "udp wss upstream"
grep -q 'network_mode: "container:openvpn-tcp-wss"' "$RENDER_NO_XRAY/pi-hole/docker-compose.yml" \
  && pass "pihole netns" || fail "pihole netns"
grep -q 'proxy_set_header Authorization' "$RENDER_XRAY/nginx-docker/nginx/conf.d/xray-api.conf" \
  && pass "xray-api proxies Authorization (dashboard JWT)" || fail "xray-api missing Authorization"
grep -q 'PIHOLE_BASE_URL=http://10.51.40.1:8080' "$RENDER_XRAY/datagate-monitor-xray/.env" \
  && pass "xray Pi-hole Base URL is TCP .1 not docker0" || fail "xray Pi-hole Base URL wrong"
grep -q 'XRAY_DNS_IDENTITY_IFACE=eth0' "$RENDER_XRAY/datagate-monitor-xray/.env" \
  && pass "XRAY_DNS_IDENTITY_IFACE=eth0" || fail "identity iface not eth0"

echo "=== ssh scenario smoke ==="
"$ROOT/scripts/smoke-test-ssh-scenarios.sh" || FAIL=1

echo "=== installer result smoke ==="
bash "$ROOT/scripts/smoke-test-install-result.sh" || FAIL=1

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== ALL SMOKE TESTS PASSED ==="
else
  echo "=== SOME TESTS FAILED ==="
  exit 1
fi
