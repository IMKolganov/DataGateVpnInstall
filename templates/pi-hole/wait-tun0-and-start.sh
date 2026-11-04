#!/bin/sh
# Runs inside datagate-pihole (host netns: shared with openvpn-tcp-wss, or network_mode host).
# The primary device carries PIHOLE_DNS_IP and is required: TCP tun, or the dg-dns dummy interface on
# hosts without OpenVPN TCP. The secondary (UDP tun) is best-effort so a delayed/failed UDP stack does
# not block Pi-hole forever.
set -eu
PRIMARY_DEV="__PIHOLE_PRIMARY_DEV__"
SECONDARY_DEV="__PIHOLE_SECONDARY_DEV__"
echo "waiting for ${PRIMARY_DEV} (required)${SECONDARY_DEV:+ and ${SECONDARY_DEV} (optional)}..."
i=0
primary_ok=0
secondary_ok=0
[ -n "$SECONDARY_DEV" ] || secondary_ok=1
while [ "$i" -lt 120 ]; do
  if [ "$primary_ok" -eq 0 ] && ip link show "$PRIMARY_DEV" >/dev/null 2>&1; then
    echo "OK  ${PRIMARY_DEV} up"
    primary_ok=1
  fi
  if [ "$secondary_ok" -eq 0 ] && ip link show "$SECONDARY_DEV" >/dev/null 2>&1; then
    echo "OK  ${SECONDARY_DEV} up"
    secondary_ok=1
  fi
  if [ "$primary_ok" -eq 1 ] && [ "$secondary_ok" -eq 1 ]; then
    echo "interfaces are up"
    exec /usr/bin/start.sh
  fi
  # After 45s with the primary only — start anyway (UDP may be recreating)
  if [ "$primary_ok" -eq 1 ] && [ "$i" -ge 45 ]; then
    echo "WARN ${SECONDARY_DEV} not up after ${i}s — starting Pi-hole on ${PRIMARY_DEV} only" >&2
    exec /usr/bin/start.sh
  fi
  i=$((i + 1))
  sleep 1
done
if [ "$primary_ok" -eq 1 ]; then
  echo "WARN ${SECONDARY_DEV} never appeared — starting Pi-hole on ${PRIMARY_DEV} only" >&2
  exec /usr/bin/start.sh
fi
echo "${PRIMARY_DEV} did not appear in 120s" >&2
exit 1
