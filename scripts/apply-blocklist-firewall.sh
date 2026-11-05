#!/usr/bin/env bash
# Reject VPN client traffic to the blocked destination ranges (blocklist/ru-services.cidrs).
#
# Rules live in their own chain, jumped to from DOCKER-USER: every forwarded packet passes DOCKER-USER
# first — OpenVPN tun traffic and the Xray bridge alike — while UFW route rules never see Docker bridge
# traffic. Docker keeps DOCKER-USER across daemon restarts; datagate-blocklist.service re-applies at boot.
# Only traffic arriving from outside WAN_IF is matched, so replies from the internet are untouched.
#
# Usage:
#   sudo ENV_FILE=~/DataGateVpnInstall/host/.env ./apply-blocklist-firewall.sh [--remove]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHAIN=DATAGATE-BLOCK
die() { echo "ERROR: $*" >&2; exit 1; }

is_true() {
  case "${1:-}" in
    true|TRUE|yes|YES|1|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

[[ "$(id -u)" -eq 0 ]] || die "run as root"

if [[ -n "${ENV_FILE:-}" ]]; then
  [[ -f "$ENV_FILE" ]] || die "env file not found: $ENV_FILE"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi
: "${WAN_IF:=eth0}"
: "${BLOCKLIST_ENABLED:=true}"
: "${BLOCKLIST_CIDRS_FILE:=$SCRIPT_DIR/blocklist/ru-services.cidrs}"

remove=0
[[ "${1:-}" == "--remove" ]] && remove=1
is_true "$BLOCKLIST_ENABLED" || remove=1

iptables -nL DOCKER-USER >/dev/null 2>&1 || die "DOCKER-USER chain missing — is Docker running?"

jump=(DOCKER-USER ! -i "$WAN_IF" -j "$CHAIN")
if [[ "$remove" -eq 1 ]]; then
  while iptables -C "${jump[@]}" 2>/dev/null; do iptables -D "${jump[@]}"; done
  if iptables -nL "$CHAIN" >/dev/null 2>&1; then
    iptables -F "$CHAIN"
    iptables -X "$CHAIN"
  fi
  echo "[blocklist] firewall rules removed"
  exit 0
fi

[[ -f "$BLOCKLIST_CIDRS_FILE" ]] || die "CIDR list not found: $BLOCKLIST_CIDRS_FILE"
cidrs=()
while IFS= read -r line; do
  line="${line%%#*}"
  line="$(echo "$line" | xargs)"
  [[ -z "$line" ]] && continue
  [[ "$line" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] || die "bad CIDR in $BLOCKLIST_CIDRS_FILE: $line"
  cidrs+=("$line")
done <"$BLOCKLIST_CIDRS_FILE"

# Build the chain fresh, then hook it in once: a re-run never leaves stale or duplicate rules.
iptables -nL "$CHAIN" >/dev/null 2>&1 || iptables -N "$CHAIN"
iptables -F "$CHAIN"
for cidr in "${cidrs[@]}"; do
  # A reset/unreachable fails the app at once instead of letting it hang on a dropped connection.
  iptables -A "$CHAIN" -d "$cidr" -p tcp -j REJECT --reject-with tcp-reset
  iptables -A "$CHAIN" -d "$cidr" -j REJECT --reject-with icmp-port-unreachable
done
iptables -C "${jump[@]}" 2>/dev/null || iptables -I "${jump[@]:0:1}" 1 "${jump[@]:1}"
echo "[blocklist] rejecting ${#cidrs[@]} range(s) for traffic not arriving on $WAN_IF"
