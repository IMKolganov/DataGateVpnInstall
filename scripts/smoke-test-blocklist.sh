#!/usr/bin/env bash
# Blocklist checks: render (always), then — when the images are cached — the firewall script against a
# throwaway iptables in a --network none container and the rendered dnsmasq file in a real Pi-hole.
# Nothing on the host (UFW, iptables, running stacks) is touched.
#
#   bash scripts/smoke-test-blocklist.sh
#   OPENVPN_TEST_IMAGE=imkolganov/datagate-monitor-openvpn:TAG PIHOLE_TEST_IMAGE=pihole/pihole:latest bash scripts/smoke-test-blocklist.sh
#
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IPT_IMAGE="${OPENVPN_TEST_IMAGE:-imkolganov/datagate-monitor-openvpn:latest}"
PIHOLE_IMAGE="${PIHOLE_TEST_IMAGE:-pihole/pihole:latest}"
pass() { echo "PASS: $*"; }
die() { echo "FAIL: $*" >&2; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/dg-blocklist-XXXXXX")"
pihole_name="dg-blocklist-pihole-$$"
cleanup() {
  docker rm -f "$pihole_name" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

render() {
  local home="$work/$1" flag="$2" xray="${3:-false}"
  cat >"$work/$1.env" <<EOF
PUBLIC_IP=203.0.113.50
INSTALL_HOME=$home
WAN_IF=eth0
INSTALL_XRAY=$xray
XRAY_DOMAIN=xray.test
XRAY_DNS_IDENTITY_SUBNET=10.80.1.0/24
BACKEND__BASEURL=https://backend.test/
UDP_WSS_DOMAIN=udp.test
TCP_WSS_DOMAIN=tcp.test
CERTBOT_EMAIL=ops@backend.test
ADMIN_SSH_IP=198.51.100.10
DASHBOARD_API_IP=203.0.113.20
TCP_VPN_SUBNET=10.51.40.0
UDP_VPN_SUBNET=10.51.42.0
PIHOLE_WEBPASSWORD=fixture-password
${flag:+BLOCKLIST_ENABLED=$flag}
EOF
  bash "$ROOT/scripts/install-vpn-host.sh" --render-only --env "$work/$1.env" >/dev/null
}

render default ""
conf="$work/default/pi-hole/etc-dnsmasq.d/10-datagate-blocklist.conf"
grep -qx 'address=/gosuslugi.ru/0.0.0.0' "$conf" || die "dnsmasq file lacks gosuslugi.ru"
grep -qx 'address=/oneme.ru/::' "$conf" || die "dnsmasq file lacks the IPv6 sinkhole"
grep -qx 'BLOCKLIST_ENABLED=true' "$work/default/host/.env" || die "host .env lacks BLOCKLIST_ENABLED"
cmp -s "$ROOT/blocklist/ru-services.cidrs" "$work/default/host/blocklist/ru-services.cidrs" || die "CIDR list not copied"
grep -q "ExecStart=$work/default/host/apply-blocklist-firewall.sh" "$work/default/host/datagate-blocklist.service" \
  || die "systemd unit not rendered"
grep -q "FTLCONF_misc_etc_dnsmasq_d: 'true'" "$work/default/pi-hole/docker-compose.yml" || die "Pi-hole does not load etc-dnsmasq.d"
pass "default: Pi-hole sinkhole file, lists, unit and host env rendered"

render withxray "" true
xray_env="$work/withxray/datagate-monitor-xray/.env"
grep -qx 'XRAY_BLOCKLIST_DOMAINS_FILE=/data/blocklist/ru-services.domains' "$xray_env" || die "xray .env lacks the domain list"
cmp -s "$ROOT/blocklist/ru-services.domains" "$work/withxray/datagate-monitor-xray/data/xray_data/blocklist/ru-services.domains" \
  || die "domain list not copied into the xray data volume"
pass "xray: lists copied to /data/blocklist and wired in .env"

render disabled false true
[[ ! -e "$work/disabled/pi-hole/etc-dnsmasq.d/10-datagate-blocklist.conf" ]] || die "disabled render still writes the sinkhole file"
! grep -q XRAY_BLOCKLIST "$work/disabled/datagate-monitor-xray/.env" || die "disabled render still wires xray blocklist"
pass "disabled: no sinkhole file, no xray blocklist"

if ! sed 's/^BLOCKLIST_ENABLED=.*/BLOCKLIST_ENABLED=maybe/' "$work/disabled.env" >"$work/bad.env" \
  || bash "$ROOT/scripts/install-vpn-host.sh" --render-only --env "$work/bad.env" >/dev/null 2>&1; then
  die "invalid BLOCKLIST_ENABLED was accepted"
fi
pass "invalid BLOCKLIST_ENABLED fails closed"

if ! command -v docker >/dev/null || ! docker image inspect "$IPT_IMAGE" >/dev/null 2>&1; then
  echo "SKIP: firewall check needs cached $IPT_IMAGE"
else
  docker run --rm --network none --cap-add NET_ADMIN -v "$work/default/host:/host:ro" --entrypoint bash "$IPT_IMAGE" -c '
    set -euo pipefail
    iptables -N DOCKER-USER && iptables -A DOCKER-USER -j RETURN
    printf "WAN_IF=eth0\nBLOCKLIST_ENABLED=true\n" >/tmp/env
    ENV_FILE=/tmp/env /host/apply-blocklist-firewall.sh >/dev/null
    ENV_FILE=/tmp/env /host/apply-blocklist-firewall.sh >/dev/null
    [[ "$(iptables -S DOCKER-USER | grep -c DATAGATE-BLOCK)" -eq 1 ]] || { echo "jump not idempotent" >&2; exit 1; }
    [[ "$(iptables -S DOCKER-USER | sed -n 2p)" == "-A DOCKER-USER ! -i eth0 -j DATAGATE-BLOCK" ]] || { echo "jump not first" >&2; exit 1; }
    iptables -C DATAGATE-BLOCK -d 213.59.252.0/22 -p tcp -j REJECT --reject-with tcp-reset
    sed -i s/=true/=false/ /tmp/env
    ENV_FILE=/tmp/env /host/apply-blocklist-firewall.sh >/dev/null
    ! iptables -nL DATAGATE-BLOCK >/dev/null 2>&1 || { echo "chain left after disable" >&2; exit 1; }
    sed -i s/=false/=true/ /tmp/env
    printf "10.0.0.0/8; rm -rf /\n" >/tmp/bad
    ! ENV_FILE=/tmp/env BLOCKLIST_CIDRS_FILE=/tmp/bad /host/apply-blocklist-firewall.sh 2>/dev/null
  ' || die "firewall script"
  pass "firewall: chain built once, jump first in DOCKER-USER, removed when disabled, bad list rejected"
fi

if ! command -v docker >/dev/null || ! docker image inspect "$PIHOLE_IMAGE" >/dev/null 2>&1; then
  echo "SKIP: Pi-hole check needs cached $PIHOLE_IMAGE"
else
  docker run -d --name "$pihole_name" \
    -e FTLCONF_dns_blocking_active=false -e FTLCONF_misc_etc_dnsmasq_d=true \
    -e FTLCONF_webserver_api_password=x -e FTLCONF_dns_listeningMode=all \
    -v "$work/default/pi-hole/etc-dnsmasq.d:/etc/dnsmasq.d:ro" "$PIHOLE_IMAGE" >/dev/null
  answer=""
  for _ in $(seq 1 30); do
    answer="$(docker exec "$pihole_name" dig @127.0.0.1 esia.gosuslugi.ru A +short +time=1 +tries=1 2>/dev/null || true)"
    [[ "$answer" =~ ^[0-9.]+$ ]] && break
    sleep 2
  done
  [[ "$answer" == "0.0.0.0" ]] || die "Pi-hole answered '$answer' for esia.gosuslugi.ru"
  [[ "$(docker exec "$pihole_name" dig @127.0.0.1 api.oneme.ru AAAA +short +time=2)" == "::" ]] || die "no IPv6 sinkhole for MAX"
  pass "Pi-hole: blocked zones and subdomains answer 0.0.0.0 / ::"
fi
