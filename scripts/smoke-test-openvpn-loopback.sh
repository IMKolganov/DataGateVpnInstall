#!/usr/bin/env bash
# Actual OpenVPN sockets in disposable, network-isolated containers. Uses an already pulled image.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${OPENVPN_TEST_IMAGE:-imkolganov/datagate-monitor-openvpn:latest}"
docker image inspect "$IMAGE" >/dev/null
test_dir="$(mktemp -d /tmp/dgsc-openvpn-loopback.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=fixture.test \
  -keyout "$test_dir/key.pem" -out "$test_dir/cert.pem" >/dev/null 2>&1
cp "$ROOT/templates/openvpn-wss-entrypoint.sh" "$test_dir/wss-entrypoint.sh"
for transport in tcp udp; do
  if [[ "$transport" == tcp ]]; then proto=tcp4-server; socket=t; else proto=udp4; socket=u; fi
  cat >"$test_dir/server.conf" <<EOF
dev tun
disable-dco
proto $proto
port 31194
tls-server
ca /check/cert.pem
cert /check/cert.pem
key /check/key.pem
dh none
server 10.255.200.0 255.255.255.0
verb 3
EOF
  for flag in true false; do
    docker run --rm --network none --cap-add NET_ADMIN --device /dev/net/tun \
      --entrypoint /bin/bash -v "$test_dir:/check:ro" \
      -e OPENVPN_WSS_ONLY="$flag" -e SOCKET_KIND="$socket" "$IMAGE" -c '
        set -euo pipefail
        source /check/wss-entrypoint.sh
        configure_openvpn_wss /run/dgsc-openvpn
        openvpn --config /check/server.conf --writepid /run/test.pid >/run/test.log 2>&1 &
        pid=$!
        trap "kill $pid 2>/dev/null || true; wait $pid 2>/dev/null || true" EXIT
        for attempt in {1..30}; do
          if ! kill -0 "$pid" 2>/dev/null; then cat /run/test.log; exit 1; fi
          listeners="$(ss -H -ln"$SOCKET_KIND" "sport = :31194" | awk "{print \$4}")"
          [[ -n "$listeners" ]] && break
          sleep 0.1
        done
        if [[ "$OPENVPN_WSS_ONLY" == true ]]; then expected=127.0.0.1:31194; else expected=0.0.0.0:31194; fi
        [[ "$listeners" == "$expected" ]] || { cat /run/test.log; echo "Unexpected sockets: $listeners"; exit 1; }
        printf "PASS: actual OpenVPN, transport=%s WSS_ONLY=%s socket=%s\n" "$SOCKET_KIND" "$OPENVPN_WSS_ONLY" "$listeners"
      '
  done
done
