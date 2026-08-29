#!/bin/sh
# Runs inside datagate-pihole (shares openvpn-tcp-wss → host netns).
# TCP tun is required (DNS for TCP clients). UDP tun is best-effort so a
# delayed/failed UDP stack does not block Pi-hole forever.
set -eu
TCP_DEV="__TCP_TUN_DEV__"
UDP_DEV="__UDP_TUN_DEV__"
echo "waiting for ${TCP_DEV} (required) and ${UDP_DEV} (optional)..."
i=0
tcp_ok=0
udp_ok=0
while [ "$i" -lt 120 ]; do
  if [ "$tcp_ok" -eq 0 ] && ip link show "$TCP_DEV" >/dev/null 2>&1; then
    echo "OK  ${TCP_DEV} up"
    tcp_ok=1
  fi
  if [ "$udp_ok" -eq 0 ] && ip link show "$UDP_DEV" >/dev/null 2>&1; then
    echo "OK  ${UDP_DEV} up"
    udp_ok=1
  fi
  if [ "$tcp_ok" -eq 1 ] && [ "$udp_ok" -eq 1 ]; then
    echo "tunnels are up"
    exec /usr/bin/start.sh
  fi
  # After 45s with TCP only — start anyway (UDP may be recreating)
  if [ "$tcp_ok" -eq 1 ] && [ "$i" -ge 45 ]; then
    echo "WARN ${UDP_DEV} not up after ${i}s — starting Pi-hole on ${TCP_DEV} only" >&2
    exec /usr/bin/start.sh
  fi
  i=$((i + 1))
  sleep 1
done
if [ "$tcp_ok" -eq 1 ]; then
  echo "WARN ${UDP_DEV} never appeared — starting Pi-hole on ${TCP_DEV} only" >&2
  exec /usr/bin/start.sh
fi
echo "${TCP_DEV} did not appear in 120s" >&2
exit 1
