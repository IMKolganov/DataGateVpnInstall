#!/usr/bin/env bash
# Render Pi-hole announce settings without starting or changing any containers.
set -euo pipefail

test_dir="$(mktemp -d /tmp/datagate-pihole-announce.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
set --
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-vpn-host.sh"

BACKEND__BASEURL=https://backend.test/
PUBLIC_IP=203.0.113.50
TCP_WSS_DOMAIN=tcp.test
UDP_WSS_DOMAIN=udp.test
TCP_VPN_SUBNET=10.51.40.0
UDP_VPN_SUBNET=10.51.42.0
TCP_DNS1=10.51.40.1
TCP_DNS2=10.51.40.1
UDP_DNS1=10.51.40.1
UDP_DNS2=10.51.40.1
TCP_PORT=1297
UDP_PORT=1194
TCP_API_PORT=5011
UDP_API_PORT=5010
TCP_MANAGEMENT_PORT=5097
UDP_MANAGEMENT_PORT=5096
TCP_TUN_DEV=tun-tcp
UDP_TUN_DEV=ovpn-udp
WAN_IF=eth0
PIHOLE_DNS_IP=10.51.40.1
PIHOLE_WEB_PORT=8090
PIHOLE_WEBPASSWORD=synthetic-fixture-credential

write_openvpn_tcp_env "$test_dir/tcp.env"
write_openvpn_udp_env "$test_dir/udp.env"
for stack in tcp udp; do
  (
    source "$test_dir/$stack.env"
    [[ "$PIHOLE_BOOTSTRAP_BASE_URL" == 'http://10.51.40.1:8090' ]]
    [[ "$PIHOLE_BOOTSTRAP_APP_PASSWORD" == "$PIHOLE_WEBPASSWORD" ]]
    if [[ "$stack" == tcp ]]; then
      [[ "$PIHOLE_BOOTSTRAP_CLIENT_SUBNET_PREFIX" == '10.51.40.' ]]
    else
      [[ "$PIHOLE_BOOTSTRAP_CLIENT_SUBNET_PREFIX" == '10.51.42.' ]]
    fi
    ! grep -q '^PIHOLE_ENABLED=' "$test_dir/$stack.env"
    if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
      docker compose --env-file "$test_dir/$stack.env" \
        -f "$TEMPLATES/openvpn-$stack-wss/docker-compose.yml" config --format json \
        >"$test_dir/$stack.json"
      python3 - "$test_dir/$stack.json" <<'PY'
import json, sys
services = json.load(open(sys.argv[1]))["services"]
env = next(iter(services.values()))["environment"]
assert env["PIHOLE_BOOTSTRAP_BASE_URL"] == "http://10.51.40.1:8090"
assert env["PIHOLE_BOOTSTRAP_APP_PASSWORD"] == "synthetic-fixture-credential"
assert "PIHOLE_ENABLED" not in env
PY
    fi
  )
  echo "PASS: $stack announces the shared Pi-hole with its own client subnet"
done
