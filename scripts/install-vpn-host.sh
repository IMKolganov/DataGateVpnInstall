#!/usr/bin/env bash
# Install a DataGate VPN host from this folder (templates + site.env).
#
# Usage:
#   1) Copy install/vpns/ to the server
#   2) cp site.env.example site.env && nano site.env
#   3) sudo ./scripts/install-vpn-host.sh
#
# Stacks: INSTALL_OPENVPN_UDP / INSTALL_OPENVPN_TCP / INSTALL_XRAY in site.env (at least one true).
#
# Flags:
#   --env FILE       path to site.env (default: ../site.env next to scripts/)
#   --wizard         ask for values interactively (writes site.env)
#   --render-only    only write stacks under INSTALL_HOME (no docker/ufw/start)
#   --skip-docker    do not install Docker
#   --skip-ufw       do not run UFW setup
#   --skip-certs     do not run certbot
#   --skip-start     do not docker compose up
#   --skip-preflight skip DNS / tun checks
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES="$ROOT_DIR/templates"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/site.env}"

WIZARD=0
RENDER_ONLY=0
SKIP_DOCKER=0
SKIP_UFW=0
SKIP_CERTS=0
SKIP_START=0
SKIP_PREFLIGHT=0

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

is_true() {
  case "${1:-}" in
    true|TRUE|yes|YES|1|on|ON) return 0 ;;
    *) return 1 ;;
  esac
}

is_ipv4() {
  [[ "${1:-}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

# Which VPN stacks this host runs (INSTALL_OPENVPN_UDP / INSTALL_OPENVPN_TCP / INSTALL_XRAY in site.env).
want_udp() { is_true "${INSTALL_OPENVPN_UDP:-true}"; }
want_tcp() { is_true "${INSTALL_OPENVPN_TCP:-true}"; }
want_xray() { is_true "${INSTALL_XRAY:-false}"; }
want_openvpn() { want_udp || want_tcp; }

# Domains that get a Let's Encrypt cert and an nginx WSS server block.
wss_domains() {
  want_udp && echo "$UDP_WSS_DOMAIN"
  want_tcp && echo "$TCP_WSS_DOMAIN"
  return 0
}

# Prefer AES-128-GCM when CPU has AES-NI (almost all cloud VPS); ChaCha only without AES-NI.
host_has_aes_ni() {
  grep -qw aes /proc/cpuinfo 2>/dev/null
}

resolve_openvpn_cipher_defaults() {
  if host_has_aes_ni; then
    DEFAULT_OVPN_CIPHER=AES-128-GCM
    DEFAULT_OVPN_DATA_CIPHERS=AES-128-GCM:CHACHA20-POLY1305
  else
    DEFAULT_OVPN_CIPHER=CHACHA20-POLY1305
    DEFAULT_OVPN_DATA_CIPHERS=CHACHA20-POLY1305:AES-128-GCM
  fi
}

usage() {
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env) ENV_FILE="$2"; shift 2 ;;
    --wizard) WIZARD=1; shift ;;
    --render-only) RENDER_ONLY=1; shift ;;
    --skip-docker) SKIP_DOCKER=1; shift ;;
    --skip-ufw) SKIP_UFW=1; shift ;;
    --skip-certs) SKIP_CERTS=1; shift ;;
    --skip-start) SKIP_START=1; shift ;;
    --skip-preflight) SKIP_PREFLIGHT=1; shift ;;
    -h|--help) usage ;;
    *) die "unknown arg: $1 (try --help)" ;;
  esac
done

chmod +x "$SCRIPT_DIR"/*.sh 2>/dev/null || true

ask() {
  local var="$1" prompt="$2" def="${3:-}" val
  if [[ -n "$def" ]]; then
    read -r -p "$prompt [$def]: " val || true
    val="${val:-$def}"
  else
    read -r -p "$prompt: " val || true
  fi
  printf -v "$var" '%s' "$val"
}

detect_ssh_client_ip() {
  local ip=""
  if [[ -n "${SSH_CLIENT:-}" ]]; then
    ip="${SSH_CLIENT%% *}"
  elif [[ -n "${SSH_CONNECTION:-}" ]]; then
    ip="${SSH_CONNECTION%% *}"
  else
    # sudo env_reset drops SSH_CLIENT — recover from live :22 session
    ip="$(ss -Htn state established '( sport = :22 )' 2>/dev/null \
      | awk 'NR==1 {print $5; exit}' \
      | sed -E 's/^\[([0-9a-fA-F:]+)\]:[0-9]+$/\1/; s/^([0-9.]+):[0-9]+$/\1/')"
  fi
  echo "$ip"
}

detect_wan_if() {
  ip -4 route show default 2>/dev/null | awk '{print $5; exit}' || echo "eth0"
}

detect_public_ip() {
  curl -4 -fsS --max-time 5 ifconfig.me 2>/dev/null \
    || curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null \
    || true
}

run_wizard() {
  info "Interactive setup — fill YOUR values (Enter keeps default)"
  local public_ip default_home ssh_ip wan_if install_xray_ans

  public_ip="$(detect_public_ip)"
  wan_if="$(detect_wan_if)"
  ssh_ip="$(detect_ssh_client_ip)"
  default_home="/home/${SUDO_USER:-${USER:-ubuntu}}"

  ask PUBLIC_IP "Public IPv4" "${public_ip}"
  ask WAN_IF "WAN interface" "${wan_if:-eth0}"
  ask INSTALL_HOME "Install home (stacks go here)" "$default_home"
  ask CERTBOT_EMAIL "Let's Encrypt email" ""
  [[ -n "$CERTBOT_EMAIL" ]] || die "CERTBOT_EMAIL is required"
  ask INSTALL_OPENVPN_UDP "Install OpenVPN UDP? (true/false)" "true"
  ask INSTALL_OPENVPN_TCP "Install OpenVPN TCP? (true/false)" "true"
  ask OPENVPN_WSS_ONLY "OpenVPN through WSS only, hide direct ports? (true/false)" "true"
  UDP_WSS_DOMAIN=""
  TCP_WSS_DOMAIN=""
  if want_udp; then
    ask UDP_WSS_DOMAIN "UDP WSS domain" ""
    [[ -n "$UDP_WSS_DOMAIN" ]] || die "UDP WSS domain is required"
  fi
  if want_tcp; then
    ask TCP_WSS_DOMAIN "TCP WSS domain" ""
    [[ -n "$TCP_WSS_DOMAIN" ]] || die "TCP WSS domain is required"
  fi
  ask HFS_DOMAIN "Optional HTTP helper domain (empty=skip)" ""
  ask BACKEND__BASEURL "Dashboard backend base URL" "https://api.datagateapp.com/"
  ask DASHBOARD_API_IP "Dashboard public IP (UFW allow API)" ""
  ask ADMIN_SSH_IP "Your SSH client IP (UFW allow 22)" "${ssh_ip}"
  ask TCP_VPN_SUBNET "TCP VPN subnet (x.y.z.0)" "10.51.40.0"
  ask UDP_VPN_SUBNET "UDP VPN subnet (x.y.z.0, unique)" "10.51.42.0"
  ask PIHOLE_WEBPASSWORD "Pi-hole web password" ""
  [[ -n "$PIHOLE_WEBPASSWORD" ]] || die "PIHOLE_WEBPASSWORD is required"
  ask install_xray_ans "Install Xray too? (true/false)" "true"

  local tcp_dns="${TCP_VPN_SUBNET%.*}.1"
  local xray_subnet="10.80.1.0"
  local xray_prefix="10.80.1."
  local xray_domain=""
  local install_xray="false"
  resolve_openvpn_cipher_defaults
  info "OpenVPN cipher default: $DEFAULT_OVPN_CIPHER (AES-NI=$(host_has_aes_ni && echo yes || echo no))"
  if ! want_openvpn && ! is_true "$install_xray_ans"; then
    die "pick at least one of OpenVPN UDP, OpenVPN TCP, Xray"
  fi
  if is_true "$install_xray_ans"; then
    install_xray="true"
    ask XRAY_DOMAIN "Xray VLESS domain" ""
    [[ -n "$XRAY_DOMAIN" ]] || die "XRAY_DOMAIN required when installing Xray"
    ask XRAY_DNS_IDENTITY_SUBNET "Xray DNS identity subnet (unique /24)" "10.80.1.0"
    xray_subnet="${XRAY_DNS_IDENTITY_SUBNET%/*}"
    xray_subnet="${xray_subnet%.0}.0"
    [[ "$xray_subnet" == *.0 ]] || xray_subnet="${XRAY_DNS_IDENTITY_SUBNET}"
    xray_prefix="${xray_subnet%.*}."
    xray_domain="$XRAY_DOMAIN"
  fi

  cat >"$ENV_FILE" <<EOF
PUBLIC_IP=${PUBLIC_IP}
WAN_IF=${WAN_IF}
INSTALL_HOME=${INSTALL_HOME}
CERTBOT_EMAIL=${CERTBOT_EMAIL}
INSTALL_OPENVPN_UDP=${INSTALL_OPENVPN_UDP}
INSTALL_OPENVPN_TCP=${INSTALL_OPENVPN_TCP}
OPENVPN_WSS_ONLY=${OPENVPN_WSS_ONLY}
BLOCKLIST_ENABLED=${BLOCKLIST_ENABLED:-true}
UDP_WSS_DOMAIN=${UDP_WSS_DOMAIN}
TCP_WSS_DOMAIN=${TCP_WSS_DOMAIN}
HFS_DOMAIN=${HFS_DOMAIN}
BACKEND__BASEURL=${BACKEND__BASEURL}
DASHBOARD_API_IP=${DASHBOARD_API_IP}
ADMIN_SSH_IP=${ADMIN_SSH_IP}
PROMETHEUS_IP=
NODE_EXPORTER_PORT=9100
DOCKER_BRIDGE_CIDR=172.17.0.0/16
TCP_VPN_SUBNET=${TCP_VPN_SUBNET}
UDP_VPN_SUBNET=${UDP_VPN_SUBNET}
TCP_DNS1=${tcp_dns}
TCP_DNS2=${tcp_dns}
UDP_DNS1=${tcp_dns}
UDP_DNS2=${tcp_dns}
PIHOLE_DNS_IP=${tcp_dns}
TCP_PORT=1297
UDP_PORT=1194
TCP_API_PORT=5011
UDP_API_PORT=5010
TCP_MANAGEMENT_PORT=5097
UDP_MANAGEMENT_PORT=5096
TCP_TUN_DEV=tun-tcp
UDP_TUN_DEV=ovpn-udp
UDP_WAN_IF=${WAN_IF}
PIHOLE_WEBPASSWORD=${PIHOLE_WEBPASSWORD}
PIHOLE_WEB_PORT=8080
TZ=UTC
ASPNETCORE_ENVIRONMENT=Production
TCP_DCO=true
UDP_DCO=true
# Auto: AES-128-GCM if host has AES-NI, else CHACHA20-POLY1305
TCP_CIPHER=${DEFAULT_OVPN_CIPHER}
TCP_DATA_CIPHERS=${DEFAULT_OVPN_DATA_CIPHERS}
UDP_CIPHER=${DEFAULT_OVPN_CIPHER}
UDP_DATA_CIPHERS=${DEFAULT_OVPN_DATA_CIPHERS}
TCP_VPN_NETMASK=255.255.255.0
UDP_VPN_NETMASK=255.255.255.0
INSTALL_DOCKER=true
SETUP_UFW=true
ISSUE_CERTS=true
START_STACKS=true
INSTALL_XRAY=${install_xray}
XRAY_DOMAIN=${xray_domain}
XRAY_MANAGER_HOST_PORT=5012
XRAY_API_HTTPS_PORT=9443
XRAY_API_ALLOW_IPS=${DASHBOARD_API_IP}
XRAY_TRANSPORT_MODE=tls
XRAY_ACCEPT_PROXY_PROTOCOL=true
# Second VLESS inbound over xHTTP on its own port (own TLS, reached directly, not via nginx).
# Looks like plain HTTP/2 traffic off :443, which is what Russian DPI currently polices hardest.
XRAY_XHTTP_ENABLED=true
XRAY_XHTTP_PORT=2053
XRAY_XHTTP_PATH=/api/v1/update
XRAY_XHTTP_MODE=auto
# Issued profiles default to xHTTP (:2053) — RF/Iran DPI fingerprints steady TLS on :443.
# Link files re-render on download; flip to primary only for soft-region nodes.
XRAY_CLIENT_LINK_TRANSPORT=xhttp
XRAY_HOST_GATEWAY=172.17.0.1
XRAY_DNS1=${tcp_dns}
XRAY_DNS2=${tcp_dns}
XRAY_PIHOLE_BASE_URL=http://${tcp_dns}:8080
XRAY_DNS_IDENTITY_ENABLED=true
XRAY_DNS_IDENTITY_SUBNET=${xray_subnet}/24
# Xray runs in Docker — identity aliases must be on container eth0, not host WAN_IF.
XRAY_DNS_IDENTITY_IFACE=eth0
XRAY_PIHOLE_CLIENT_SUBNET_PREFIX=${xray_prefix}
XRAY_PIHOLE_EXCLUDE_PREFIXES=${TCP_VPN_SUBNET%.*}.,${UDP_VPN_SUBNET%.*}.
NGINX_CERTBOT_CONF=${INSTALL_HOME}/nginx-docker/certbot/conf
EOF
  info "Wrote $ENV_FILE"
}

reject_placeholder() {
  local name="$1" val="$2"
  if [[ -z "$val" ]]; then
    die "$name is empty — edit $ENV_FILE"
  fi
  if [[ "$val" == *YOUR_* ]] || [[ "$val" == *CHANGE_ME* ]] \
    || [[ "$val" == *example.com* ]] || [[ "$val" == *yourdomain.com* ]]; then
    die "$name still looks like a placeholder ($val) — edit $ENV_FILE"
  fi
}

load_env() {
  [[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE — copy site.env.example or run with --wizard"
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a

  : "${PUBLIC_IP:?PUBLIC_IP required}"
  : "${INSTALL_HOME:?INSTALL_HOME required}"
  : "${INSTALL_OPENVPN_UDP:=true}"
  : "${INSTALL_OPENVPN_TCP:=true}"
  : "${OPENVPN_WSS_ONLY:=true}"
  case "$OPENVPN_WSS_ONLY" in
    true|TRUE|yes|YES|1|on|ON|false|FALSE|no|NO|0|off|OFF) ;;
    *) die "OPENVPN_WSS_ONLY must be true or false" ;;
  esac
  : "${BLOCKLIST_ENABLED:=true}"
  case "$BLOCKLIST_ENABLED" in
    true|TRUE|yes|YES|1|on|ON|false|FALSE|no|NO|0|off|OFF) ;;
    *) die "BLOCKLIST_ENABLED must be true or false" ;;
  esac
  : "${INSTALL_XRAY:=false}"
  : "${UDP_WSS_DOMAIN:=}"
  : "${TCP_WSS_DOMAIN:=}"
  want_openvpn || want_xray \
    || die "nothing to install — set at least one of INSTALL_OPENVPN_UDP, INSTALL_OPENVPN_TCP, INSTALL_XRAY to true"
  : "${TCP_VPN_SUBNET:?TCP_VPN_SUBNET required}"
  : "${UDP_VPN_SUBNET:?UDP_VPN_SUBNET required}"
  : "${BACKEND__BASEURL:?BACKEND__BASEURL required}"
  : "${ADMIN_SSH_IP:?ADMIN_SSH_IP required}"
  : "${DASHBOARD_API_IP:?DASHBOARD_API_IP required}"
  : "${PIHOLE_WEBPASSWORD:?PIHOLE_WEBPASSWORD required}"
  : "${CERTBOT_EMAIL:=}"
  : "${WAN_IF:=}"
  : "${TCP_PORT:=1297}"
  : "${UDP_PORT:=1194}"
  : "${TCP_API_PORT:=5011}"
  : "${UDP_API_PORT:=5010}"
  : "${TCP_MANAGEMENT_PORT:=5097}"
  : "${UDP_MANAGEMENT_PORT:=5096}"
  : "${TCP_TUN_DEV:=tun-tcp}"
  : "${UDP_TUN_DEV:=ovpn-udp}"
  : "${PIHOLE_WEB_PORT:=8080}"
  : "${TZ:=UTC}"
  : "${DOCKER_BRIDGE_CIDR:=172.17.0.0/16}"
  : "${DNS_DUMMY_DEV:=dg-dns}"

  resolve_openvpn_cipher_defaults
  : "${TCP_CIPHER:=$DEFAULT_OVPN_CIPHER}"
  : "${TCP_DATA_CIPHERS:=$DEFAULT_OVPN_DATA_CIPHERS}"
  : "${UDP_CIPHER:=$DEFAULT_OVPN_CIPHER}"
  : "${UDP_DATA_CIPHERS:=$DEFAULT_OVPN_DATA_CIPHERS}"
  info "OpenVPN ciphers: TCP=$TCP_CIPHER UDP=$UDP_CIPHER (AES-NI=$(host_has_aes_ni && echo yes || echo no))"

  # Derive DNS from TCP subnet if missing / still placeholder
  local tcp_dns="${TCP_VPN_SUBNET%.*}.1"
  : "${TCP_DNS1:=$tcp_dns}"
  : "${TCP_DNS2:=$tcp_dns}"
  : "${UDP_DNS1:=$tcp_dns}"
  : "${UDP_DNS2:=$tcp_dns}"
  : "${PIHOLE_DNS_IP:=$tcp_dns}"
  TCP_DNS1="$tcp_dns"
  TCP_DNS2="$tcp_dns"
  UDP_DNS1="$tcp_dns"
  UDP_DNS2="$tcp_dns"
  PIHOLE_DNS_IP="$tcp_dns"

  # Pi-hole answers on TCP tun .1. Without the TCP stack the same address lives on a dummy interface, so
  # UDP clients and Xray keep the DNS IP, UFW rules and Pi-hole history they would have with TCP.
  if want_tcp; then
    PIHOLE_PRIMARY_DEV="$TCP_TUN_DEV"
  else
    PIHOLE_PRIMARY_DEV="$DNS_DUMMY_DEV"
  fi
  PIHOLE_SECONDARY_DEV=""
  want_udp && PIHOLE_SECONDARY_DEV="$UDP_TUN_DEV"

  if [[ -z "$WAN_IF" || "$WAN_IF" == YOUR_* ]]; then
    WAN_IF="$(detect_wan_if)"
    : "${WAN_IF:=eth0}"
  fi
  : "${UDP_WAN_IF:=$WAN_IF}"

  reject_placeholder PUBLIC_IP "$PUBLIC_IP"
  reject_placeholder INSTALL_HOME "$INSTALL_HOME"
  want_udp && reject_placeholder UDP_WSS_DOMAIN "$UDP_WSS_DOMAIN"
  want_tcp && reject_placeholder TCP_WSS_DOMAIN "$TCP_WSS_DOMAIN"
  reject_placeholder BACKEND__BASEURL "$BACKEND__BASEURL"
  reject_placeholder PIHOLE_WEBPASSWORD "$PIHOLE_WEBPASSWORD"
  reject_placeholder ADMIN_SSH_IP "$ADMIN_SSH_IP"
  reject_placeholder DASHBOARD_API_IP "$DASHBOARD_API_IP"

  is_ipv4 "$PUBLIC_IP" || die "PUBLIC_IP must be IPv4 (got: $PUBLIC_IP)"
  is_ipv4 "$ADMIN_SSH_IP" || die "ADMIN_SSH_IP must be IPv4 — wrong value locks you out of SSH (got: $ADMIN_SSH_IP)"
  is_ipv4 "$DASHBOARD_API_IP" || die "DASHBOARD_API_IP must be IPv4 (got: $DASHBOARD_API_IP)"

  if [[ "$TCP_VPN_SUBNET" == "$UDP_VPN_SUBNET" ]]; then
    die "TCP_VPN_SUBNET and UDP_VPN_SUBNET must be different"
  fi

  if is_true "${INSTALL_XRAY:-false}"; then
    local id_prefix="${XRAY_DNS_IDENTITY_SUBNET%/*}"
    id_prefix="${id_prefix%.*}"
    local tcp_prefix="${TCP_VPN_SUBNET%.*}"
    local udp_prefix="${UDP_VPN_SUBNET%.*}"
    if [[ "$id_prefix" == "$tcp_prefix" || "$id_prefix" == "$udp_prefix" ]]; then
      die "XRAY_DNS_IDENTITY_SUBNET (${XRAY_DNS_IDENTITY_SUBNET}) must not share the same /24 as TCP or UDP VPN subnets"
    fi
    if [[ ! "$XRAY_DNS_IDENTITY_SUBNET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]+$ ]]; then
      die "XRAY_DNS_IDENTITY_SUBNET must look like 10.80.1.0/24 (got: $XRAY_DNS_IDENTITY_SUBNET)"
    fi
  fi

  if is_true "${ISSUE_CERTS:-true}" && [[ "$SKIP_CERTS" -eq 0 ]]; then
    reject_placeholder CERTBOT_EMAIL "${CERTBOT_EMAIL:-}"
  fi

  if is_true "${INSTALL_XRAY:-false}"; then
    reject_placeholder XRAY_DOMAIN "${XRAY_DOMAIN:-}"
    : "${XRAY_DNS_IDENTITY_SUBNET:?XRAY_DNS_IDENTITY_SUBNET required when INSTALL_XRAY=true}"
    reject_placeholder XRAY_DNS_IDENTITY_SUBNET "$XRAY_DNS_IDENTITY_SUBNET"
    : "${XRAY_API_ALLOW_IPS:=$DASHBOARD_API_IP}"
    # Always sync from current subnets — site.env.example values (10.51.40.1 / 10.80.1.)
    # must not stick after the operator changes TCP/UDP/identity ranges.
    XRAY_DNS1="$tcp_dns"
    XRAY_DNS2="$tcp_dns"
    XRAY_PIHOLE_BASE_URL="http://${tcp_dns}:${PIHOLE_WEB_PORT:-8080}"
    XRAY_PIHOLE_EXCLUDE_PREFIXES="${TCP_VPN_SUBNET%.*}.,${UDP_VPN_SUBNET%.*}."
    XRAY_PIHOLE_CLIENT_SUBNET_PREFIX="${XRAY_DNS_IDENTITY_SUBNET%.*}."
    # Container eth0 only — host WAN names break identity aliases (hel/pol class bug).
    if [[ -n "${XRAY_DNS_IDENTITY_IFACE:-}" && "$XRAY_DNS_IDENTITY_IFACE" != "eth0" ]]; then
      warn "XRAY_DNS_IDENTITY_IFACE=${XRAY_DNS_IDENTITY_IFACE} overridden → eth0 (must be container iface)"
    fi
    XRAY_DNS_IDENTITY_IFACE=eth0
    : "${NGINX_CERTBOT_CONF:=$INSTALL_HOME/nginx-docker/certbot/conf}"
    reject_placeholder XRAY_API_ALLOW_IPS "$XRAY_API_ALLOW_IPS"
    # Every allow IP must look like IPv4 (comma-separated OK)
    local _ip
    IFS=',' read -ra _allow <<< "$XRAY_API_ALLOW_IPS"
    for _ip in "${_allow[@]}"; do
      _ip="$(echo "$_ip" | xargs)"
      [[ -z "$_ip" ]] && continue
      is_ipv4 "$_ip" || die "XRAY_API_ALLOW_IPS entry must be IPv4 (got: $_ip)"
    done
    if is_true "${XRAY_XHTTP_ENABLED:-true}"; then
      : "${XRAY_XHTTP_PORT:=2053}"
      [[ "$XRAY_XHTTP_PORT" =~ ^[0-9]+$ ]] && ((XRAY_XHTTP_PORT >= 1 && XRAY_XHTTP_PORT <= 65535)) \
        || die "XRAY_XHTTP_PORT must be 1-65535 (got: $XRAY_XHTTP_PORT)"
      # Docker publishes this port, so a collision fails `compose up` and takes the whole Xray
      # container down — reject it here instead of at deploy time.
      local _busy _label
      for _busy in \
        "80:http certbot" "443:nginx SNI mux" "22:ssh" "8443:nginx local https" \
        "${XRAY_API_HTTPS_PORT:-9443}:xray manager api" \
        "${XRAY_MANAGER_HOST_PORT:-5012}:xray manager host port" \
        "${TCP_PORT:-1195}:OpenVPN TCP" "${TCP_API_PORT:-5011}:OpenVPN TCP api" \
        "${UDP_API_PORT:-5010}:OpenVPN UDP api" "${PIHOLE_WEB_PORT:-8080}:Pi-hole web"; do
        _label="${_busy#*:}"
        if [[ "$XRAY_XHTTP_PORT" == "${_busy%%:*}" ]]; then
          die "XRAY_XHTTP_PORT=$XRAY_XHTTP_PORT is already used by $_label — pick a free port (default 2053)"
        fi
      done
      : "${XRAY_XHTTP_PATH:=/api/v1/update}"
      [[ "$XRAY_XHTTP_PATH" == /* ]] || die "XRAY_XHTTP_PATH must start with '/' (got: $XRAY_XHTTP_PATH)"
      info "Xray xHTTP inbound: port=$XRAY_XHTTP_PORT path=$XRAY_XHTTP_PATH mode=${XRAY_XHTTP_MODE:-auto}"
    fi
    : "${XRAY_CLIENT_LINK_TRANSPORT:=xhttp}"
    case "$XRAY_CLIENT_LINK_TRANSPORT" in
      primary|xhttp) ;;
      *) die "XRAY_CLIENT_LINK_TRANSPORT must be 'primary' or 'xhttp' (got: $XRAY_CLIENT_LINK_TRANSPORT)" ;;
    esac
    if [[ "$XRAY_CLIENT_LINK_TRANSPORT" == "xhttp" ]] && ! is_true "${XRAY_XHTTP_ENABLED:-true}"; then
      die "XRAY_CLIENT_LINK_TRANSPORT=xhttp requires XRAY_XHTTP_ENABLED=true"
    fi
    info "Xray client link transport: $XRAY_CLIENT_LINK_TRANSPORT (issued {{vless_uri}})"
    info "Xray Pi-hole: BaseURL=$XRAY_PIHOLE_BASE_URL prefix=$XRAY_PIHOLE_CLIENT_SUBNET_PREFIX iface=eth0"
  fi

  # Remember SSH client for UFW safety net
  export INSTALLER_SSH_CLIENT_IP
  INSTALLER_SSH_CLIENT_IP="$(detect_ssh_client_ip)"
}

preflight() {
  [[ "$SKIP_PREFLIGHT" -eq 1 ]] && { warn "preflight skipped"; return 0; }
  info "Preflight checks"

  if want_openvpn && [[ ! -e /dev/net/tun ]]; then
    die "/dev/net/tun missing — load tun module: sudo modprobe tun"
  fi

  if [[ "$RENDER_ONLY" -eq 0 ]] && is_true "${ISSUE_CERTS:-true}" && [[ "$SKIP_CERTS" -eq 0 ]]; then
    local d resolved
    for d in $(wss_domains); do
      resolved="$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1; exit}' || true)"
      if [[ -z "$resolved" ]]; then
        warn "DNS for $d does not resolve yet — certbot will fail until A-record → $PUBLIC_IP"
      elif [[ "$resolved" != "$PUBLIC_IP" ]]; then
        warn "DNS for $d → $resolved (expected $PUBLIC_IP) — fix A-record before certbot"
      else
        info "DNS OK: $d → $resolved"
      fi
    done
    if is_true "${INSTALL_XRAY:-false}"; then
      resolved="$(getent ahostsv4 "$XRAY_DOMAIN" 2>/dev/null | awk '{print $1; exit}' || true)"
      if [[ -z "$resolved" ]]; then
        warn "DNS for $XRAY_DOMAIN does not resolve yet"
      elif [[ "$resolved" != "$PUBLIC_IP" ]]; then
        warn "DNS for $XRAY_DOMAIN → $resolved (expected $PUBLIC_IP)"
      else
        info "DNS OK: $XRAY_DOMAIN → $resolved"
      fi
    fi
  fi
}

render_file() {
  local src="$1" dst="$2"
  local content k v
  content="$(cat "$src")"
  local keys=(
    PUBLIC_IP WAN_IF INSTALL_HOME CERTBOT_EMAIL
    UDP_WSS_DOMAIN TCP_WSS_DOMAIN HFS_DOMAIN XRAY_DOMAIN XRAY_API_HTTPS_PORT
    BACKEND__BASEURL DASHBOARD_API_IP ADMIN_SSH_IP
    PROMETHEUS_IP NODE_EXPORTER_PORT DOCKER_BRIDGE_CIDR
    TCP_VPN_SUBNET UDP_VPN_SUBNET TCP_DNS1 TCP_DNS2 UDP_DNS1 UDP_DNS2 PIHOLE_DNS_IP
    TCP_PORT UDP_PORT TCP_API_PORT UDP_API_PORT TCP_MANAGEMENT_PORT UDP_MANAGEMENT_PORT
    TCP_TUN_DEV UDP_TUN_DEV UDP_WAN_IF DNS_DUMMY_DEV PIHOLE_PRIMARY_DEV PIHOLE_SECONDARY_DEV
    PIHOLE_WEBPASSWORD PIHOLE_WEB_PORT TZ
    ASPNETCORE_ENVIRONMENT TCP_DCO UDP_DCO TCP_CIPHER TCP_DATA_CIPHERS UDP_CIPHER UDP_DATA_CIPHERS
    TCP_VPN_NETMASK UDP_VPN_NETMASK
  )
  for k in "${keys[@]}"; do
    v="${!k-}"
    content="${content//__${k}__/${v}}"
  done

  if grep -qE '__[A-Z0-9_]+__' <<<"$content"; then
    warn "unresolved placeholders in $dst:"
    grep -oE '__[A-Z0-9_]+__' <<<"$content" | sort -u >&2 || true
  fi

  mkdir -p "$(dirname "$dst")"
  printf '%s\n' "$content" >"$dst"
}

write_openvpn_tcp_env() {
  local dest="$1"
  # Per-stack announce URL (TCP ≠ UDP). Do not reuse a single site.env PUBLIC_API_URL.
  local api_url="https://${TCP_WSS_DOMAIN}/"
  cat >"$dest" <<EOF
BACKEND__BASEURL=${BACKEND__BASEURL}
ASPNETCORE_ENVIRONMENT=${ASPNETCORE_ENVIRONMENT:-Production}
PUBLIC_IP=${PUBLIC_IP}
PUBLIC_API_URL=${api_url}
OPENVPN_WSS_ONLY=${OPENVPN_WSS_ONLY:-true}
TCP_VPN_SUBNET=${TCP_VPN_SUBNET}
TCP_VPN_NETMASK=${TCP_VPN_NETMASK:-255.255.255.0}
TCP_DNS1=${TCP_DNS1}
TCP_DNS2=${TCP_DNS2}
TCP_PORT=${TCP_PORT}
TCP_API_PORT=${TCP_API_PORT}
TCP_MANAGEMENT_PORT=${TCP_MANAGEMENT_PORT}
TCP_TUN_DEV=${TCP_TUN_DEV}
TCP_TUN_IF=${TCP_TUN_DEV}
TCP_DCO=${TCP_DCO:-true}
TCP_CIPHER=${TCP_CIPHER:-AES-128-GCM}
TCP_DATA_CIPHERS=${TCP_DATA_CIPHERS:-AES-128-GCM:CHACHA20-POLY1305}
PIHOLE_BOOTSTRAP_BASE_URL=http://${PIHOLE_DNS_IP}:${PIHOLE_WEB_PORT:-8080}
PIHOLE_BOOTSTRAP_APP_PASSWORD=${PIHOLE_WEBPASSWORD}
PIHOLE_BOOTSTRAP_CLIENT_SUBNET_PREFIX=${TCP_VPN_SUBNET%.*}.
EOF
}

write_openvpn_udp_env() {
  local dest="$1"
  # Per-stack announce URL (UDP ≠ TCP). Do not reuse a single site.env PUBLIC_API_URL.
  local api_url="https://${UDP_WSS_DOMAIN}/"
  cat >"$dest" <<EOF
BACKEND__BASEURL=${BACKEND__BASEURL}
ASPNETCORE_ENVIRONMENT=${ASPNETCORE_ENVIRONMENT:-Production}
PUBLIC_IP=${PUBLIC_IP}
PUBLIC_API_URL=${api_url}
OPENVPN_WSS_ONLY=${OPENVPN_WSS_ONLY:-true}
UDP_VPN_SUBNET=${UDP_VPN_SUBNET}
UDP_VPN_NETMASK=${UDP_VPN_NETMASK:-255.255.255.0}
UDP_DNS1=${UDP_DNS1}
UDP_DNS2=${UDP_DNS2}
UDP_PORT=${UDP_PORT}
UDP_API_PORT=${UDP_API_PORT}
UDP_MANAGEMENT_PORT=${UDP_MANAGEMENT_PORT}
UDP_TUN_DEV=${UDP_TUN_DEV}
UDP_WAN_IF=${UDP_WAN_IF:-$WAN_IF}
UDP_DCO=${UDP_DCO:-true}
UDP_CIPHER=${UDP_CIPHER:-AES-128-GCM}
UDP_DATA_CIPHERS=${UDP_DATA_CIPHERS:-AES-128-GCM:CHACHA20-POLY1305}
PIHOLE_BOOTSTRAP_BASE_URL=http://${PIHOLE_DNS_IP}:${PIHOLE_WEB_PORT:-8080}
PIHOLE_BOOTSTRAP_APP_PASSWORD=${PIHOLE_WEBPASSWORD}
PIHOLE_BOOTSTRAP_CLIENT_SUBNET_PREFIX=${UDP_VPN_SUBNET%.*}.
EOF
}

write_pihole_env() {
  local dest="$1"
  cat >"$dest" <<EOF
TZ=${TZ:-UTC}
PIHOLE_WEBPASSWORD=${PIHOLE_WEBPASSWORD}
PIHOLE_DNS_INTERFACE=${PIHOLE_PRIMARY_DEV}${PIHOLE_SECONDARY_DEV:+,${PIHOLE_SECONDARY_DEV}}
PIHOLE_WEB_PORT=${PIHOLE_WEB_PORT:-8080}
EOF
}

write_host_env() {
  local dest="$1"
  # Docker publishes the xHTTP port itself (its iptables rules bypass UFW), but the UFW rule keeps
  # `ufw status` honest about what is reachable on this host.
  local extra_tcp_port=""
  if is_true "${INSTALL_XRAY:-false}" && is_true "${XRAY_XHTTP_ENABLED:-true}"; then
    extra_tcp_port="${XRAY_XHTTP_PORT:-2053}"
  fi
  cat >"$dest" <<EOF
OPENVPN_TCP=$(want_tcp && echo true || echo false)
OPENVPN_UDP=$(want_udp && echo true || echo false)
OPENVPN_WSS_ONLY=${OPENVPN_WSS_ONLY:-true}
BLOCKLIST_ENABLED=${BLOCKLIST_ENABLED:-true}
TCP_VPN_SUBNET=${TCP_VPN_SUBNET}
UDP_VPN_SUBNET=${UDP_VPN_SUBNET}
PIHOLE_DNS_IP=${PIHOLE_DNS_IP}
PIHOLE_WEB_PORT=${PIHOLE_WEB_PORT:-8080}
TCP_TUN_DEV=${TCP_TUN_DEV}
UDP_TUN_DEV=${UDP_TUN_DEV}
TCP_PORT=${TCP_PORT}
UDP_PORT=${UDP_PORT}
TCP_API_PORT=${TCP_API_PORT}
UDP_API_PORT=${UDP_API_PORT}
WAN_IF=${WAN_IF}
ADMIN_SSH_IP=${ADMIN_SSH_IP}
DASHBOARD_API_IP=${DASHBOARD_API_IP}
PROMETHEUS_IP=${PROMETHEUS_IP:-}
DOCKER_BRIDGE_CIDR=${DOCKER_BRIDGE_CIDR}
NODE_EXPORTER_PORT=${NODE_EXPORTER_PORT:-9100}
INSTALLER_SSH_CLIENT_IP=${INSTALLER_SSH_CLIENT_IP:-}
EXTRA_TCP_PORT=${extra_tcp_port}
EOF
  if is_true "${INSTALL_XRAY:-false}"; then
    cat >>"$dest" <<EOF
XRAY_API_HTTPS_PORT=${XRAY_API_HTTPS_PORT:-9443}
XRAY_API_ALLOW_IPS=${XRAY_API_ALLOW_IPS:-${DASHBOARD_API_IP}}
XRAY_DNS_IDENTITY_SUBNET=${XRAY_DNS_IDENTITY_SUBNET}
EOF
  fi
}

xray_api_allow_block() {
  local ips="${XRAY_API_ALLOW_IPS:-${DASHBOARD_API_IP}}" ip
  IFS=',' read -ra _ips <<<"$ips"
  for ip in "${_ips[@]}"; do
    ip="$(echo "$ip" | xargs)"
    [[ -z "$ip" || "$ip" == YOUR_* ]] && continue
    is_ipv4 "$ip" || continue
    printf '        allow %s;\n' "$ip"
  done
}

write_stream_conf() {
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  if is_true "${INSTALL_XRAY:-false}" && [[ -n "${XRAY_DOMAIN:-}" ]]; then
    render_file "$TEMPLATES/nginx-docker/nginx/stream.d/sni-xray.conf" "$dest"
  else
    cat >"$dest" <<'EOF'
upstream local_https {
    server 127.0.0.1:8443;
}

server {
    listen 443;
    listen [::]:443;
    ssl_preread on;
    proxy_pass local_https;
    proxy_protocol on;
    proxy_connect_timeout 10s;
    proxy_timeout 1d;
}
EOF
  fi
}

write_acme_conf() {
  local conf_d="$1" mode="${2:-waiting}"
  local names
  names="$(wss_domains | xargs)"
  if is_true "${INSTALL_XRAY:-false}" && [[ -n "${XRAY_DOMAIN:-}" ]]; then
    names+=" ${XRAY_DOMAIN}"
  fi
  if [[ -n "${HFS_DOMAIN:-}" ]]; then
    names+=" ${HFS_DOMAIN}"
  fi
  names="$(xargs <<<"$names")"

  local trailing
  if [[ "$mode" == "redirect" ]]; then
    trailing='        return 301 https://$host$request_uri;'
  else
    trailing="        return 200 'waiting for TLS cert';
        add_header Content-Type text/plain;"
  fi

  cat >"$conf_d/00-acme.conf" <<EOF
server {
    listen 80;
    server_name ${names};

    location /.well-known/acme-challenge/ {
        root /var/www/certbot;
    }

    location / {
${trailing}
    }
}
EOF
}

tls_certs_ready() {
  local home="$1"
  local cert_root="$home/nginx-docker/certbot/conf/live" d
  for d in $(wss_domains); do
    [[ -f "$cert_root/$d/fullchain.pem" ]] || return 1
  done
  if want_xray; then
    [[ -f "$cert_root/${XRAY_DOMAIN}/fullchain.pem" ]] || return 1
  fi
  return 0
}

write_simple_stream_conf() {
  # No Xray upstream — safe for ACME before datagate-monitor-xray exists.
  local dest="$1"
  mkdir -p "$(dirname "$dest")"
  cat >"$dest" <<'EOF'
upstream local_https {
    server 127.0.0.1:8443;
}

server {
    listen 443;
    listen [::]:443;
    ssl_preread on;
    proxy_pass local_https;
    proxy_protocol on;
    proxy_connect_timeout 10s;
    proxy_timeout 1d;
}
EOF
}

write_http_only_nginx() {
  local conf_d="$1"
  local stream_d="$2"
  mkdir -p "$conf_d" "$stream_d" "$(dirname "$conf_d")/../logs"

  cp "$TEMPLATES/nginx-docker/nginx/nginx.conf" "$(dirname "$conf_d")/nginx.conf"
  # Always simple stream during ACME — Xray SNI comes after certs + start_xray
  write_simple_stream_conf "$stream_d/sni-xray.conf"
  write_acme_conf "$conf_d" waiting
  rm -f "$conf_d/udp-wss.conf" "$conf_d/tcp-wss.conf" "$conf_d/xray-api.conf" "$conf_d/00-map.conf"
}

write_full_nginx() {
  local conf_d="$1"
  local stream_d="$2"
  mkdir -p "$conf_d" "$stream_d"

  cp "$TEMPLATES/nginx-docker/nginx/nginx.conf" "$(dirname "$conf_d")/nginx.conf"
  write_stream_conf "$stream_d/sni-xray.conf"
  write_acme_conf "$conf_d" redirect

  : "${XRAY_API_HTTPS_PORT:=9443}"
  local allow_block
  allow_block="$(xray_api_allow_block)"

  if want_udp; then
    render_file "$TEMPLATES/nginx-docker/nginx/conf.d/udp-wss.conf" "$conf_d/udp-wss.conf"
  else
    rm -f "$conf_d/udp-wss.conf"
  fi
  if want_tcp; then
    render_file "$TEMPLATES/nginx-docker/nginx/conf.d/tcp-wss.conf" "$conf_d/tcp-wss.conf"
  else
    rm -f "$conf_d/tcp-wss.conf"
  fi

  if is_true "${INSTALL_XRAY:-false}"; then
    if [[ -z "$allow_block" ]]; then
      die "XRAY_API_ALLOW_IPS produced no allow lines — set at least DASHBOARD_API_IP"
    fi
    cat >"$conf_d/xray-api.conf" <<EOF
# Xray manager API — separate port, does not collide with VLESS on :443
server {
    listen ${XRAY_API_HTTPS_PORT:-9443} ssl;
    http2 on;
    server_name ${XRAY_DOMAIN};

    ssl_certificate /etc/letsencrypt/live/${XRAY_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${XRAY_DOMAIN}/privkey.pem;

    location / {
${allow_block}
        deny all;

        resolver 127.0.0.11 valid=10s ipv6=off;
        set \$xray_api_upstream datagate-monitor-xray;
        proxy_pass http://\$xray_api_upstream:5010;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        # Required: dashboard microservice JWT (same as OpenVPN WSS confs)
        proxy_set_header Authorization \$http_authorization;
        proxy_read_timeout 86400s;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
EOF
  else
    rm -f "$conf_d/xray-api.conf"
  fi
}

write_nginx_env() {
  local dest="$1"
  cat >"$dest" <<EOF
XRAY_API_HTTPS_PORT=${XRAY_API_HTTPS_PORT:-9443}
EOF
}

sync_xray_dns_route_assets() {
  [[ -n "${XRAY_DNS_IDENTITY_SUBNET:-}" ]] || return 0
  local home="$INSTALL_HOME"
  mkdir -p "$home/host"
  cp "$SCRIPT_DIR/setup-xray-dns-identity-route.sh" "$home/host/setup-xray-dns-identity-route.sh"
  chmod +x "$home/host/setup-xray-dns-identity-route.sh"
  render_file "$TEMPLATES/host/datagate-xray-dns-route.service" "$home/host/datagate-xray-dns-route.service"
}

# Without the TCP stack Pi-hole binds PIHOLE_DNS_IP on a dummy interface created before docker starts.
sync_dns_dummy_assets() {
  local home="$INSTALL_HOME"
  mkdir -p "$home/host"
  render_file "$TEMPLATES/host/datagate-dns-dummy.service" "$home/host/datagate-dns-dummy.service"
}

# Blocked destinations (blocklist/): Pi-hole answers 0.0.0.0/:: for the domains, and
# apply-blocklist-firewall.sh rejects the dedicated ranges for all forwarded VPN traffic.
sync_blocklist_assets() {
  local home="$INSTALL_HOME"
  mkdir -p "$home/host/blocklist"
  cp "$ROOT_DIR/blocklist/ru-services.domains" "$ROOT_DIR/blocklist/ru-services.cidrs" "$home/host/blocklist/"
  cp "$SCRIPT_DIR/apply-blocklist-firewall.sh" "$home/host/apply-blocklist-firewall.sh"
  chmod +x "$home/host/apply-blocklist-firewall.sh"
  render_file "$TEMPLATES/host/datagate-blocklist.service" "$home/host/datagate-blocklist.service"
}

write_pihole_blocklist() {
  local dest="$1" domain
  if ! is_true "$BLOCKLIST_ENABLED"; then
    rm -f "$dest"
    return 0
  fi
  {
    echo "# Rendered by install-vpn-host.sh from blocklist/ru-services.domains — do not edit here."
    while IFS= read -r domain; do
      domain="${domain%%#*}"
      domain="$(echo "$domain" | xargs)"
      [[ -z "$domain" ]] && continue
      [[ "$domain" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || die "bad domain in blocklist: $domain"
      # address=/d/ also covers every subdomain of d.
      echo "address=/${domain}/0.0.0.0"
      echo "address=/${domain}/::"
    done <"$ROOT_DIR/blocklist/ru-services.domains"
  } >"$dest"
}

install_blocklist_service() {
  local unit_src="$INSTALL_HOME/host/datagate-blocklist.service"
  if grep -qE '__[A-Z0-9_]+__' "$unit_src"; then
    warn "unresolved placeholders in $unit_src — fix INSTALL_HOME in site.env and re-render"
    return 0
  fi
  if ! is_true "$BLOCKLIST_ENABLED"; then
    systemctl disable --now datagate-blocklist.service >/dev/null 2>&1 || true
    ENV_FILE="$INSTALL_HOME/host/.env" "$INSTALL_HOME/host/apply-blocklist-firewall.sh" --remove \
      || warn "could not remove blocklist firewall rules"
    return 0
  fi
  info "Enabling systemd unit for blocked VPN destinations (survives reboot)"
  install -m 0644 "$unit_src" /etc/systemd/system/datagate-blocklist.service
  systemctl daemon-reload
  systemctl enable datagate-blocklist.service
  # restart, not start: a re-install must re-read an updated CIDR list.
  systemctl restart datagate-blocklist.service || warn "datagate-blocklist.service failed — check: journalctl -u datagate-blocklist"
}

write_pihole_compose() {
  local dest="$1"
  if want_tcp; then
    cp "$TEMPLATES/pi-hole/docker-compose.yml" "$dest"
  else
    sed 's|^    network_mode: "container:openvpn-tcp-wss"$|    network_mode: host|' \
      "$TEMPLATES/pi-hole/docker-compose.yml" >"$dest"
    grep -q '^    network_mode: host$' "$dest" || die "pi-hole compose template: network_mode line not found"
  fi
}

# Pi-hole joins openvpn-tcp-wss netns by container id — recreate after TCP reboot/recreate.
sync_pihole_after_tcp_assets() {
  local home="$INSTALL_HOME"
  mkdir -p "$home/host"
  cp "$SCRIPT_DIR/recreate-pihole-after-tcp.sh" "$home/host/recreate-pihole-after-tcp.sh"
  cp "$SCRIPT_DIR/watch-pihole-after-tcp.sh" "$home/host/watch-pihole-after-tcp.sh"
  chmod +x "$home/host/recreate-pihole-after-tcp.sh" "$home/host/watch-pihole-after-tcp.sh"
  render_file "$TEMPLATES/host/datagate-pihole-after-tcp.service" "$home/host/datagate-pihole-after-tcp.service"
}

write_xray_env() {
  local dest="$1"
  local nginx_certs="${NGINX_CERTBOT_CONF:-$INSTALL_HOME/nginx-docker/certbot/conf}"
  local exclude="${TCP_VPN_SUBNET%.*}.,${UDP_VPN_SUBNET%.*}."
  local prefix="${XRAY_DNS_IDENTITY_SUBNET%.*}."
  local gw="${XRAY_HOST_GATEWAY:-172.17.0.1}"
  local pihole_dns="${PIHOLE_DNS_IP:-${TCP_VPN_SUBNET%.*}.1}"
  local api_https_port="${XRAY_API_HTTPS_PORT:-9443}"
  # Prefer nginx HTTPS front (:9443), not the in-container API_PORT fallback.
  local api_url="https://${XRAY_DOMAIN}:${api_https_port}/"
  cat >"$dest" <<EOF
ASPNETCORE_ENVIRONMENT=${ASPNETCORE_ENVIRONMENT:-Production}
BACKEND__BASEURL=${BACKEND__BASEURL}
PUBLIC_IP=${PUBLIC_IP}
PUBLIC_API_URL=${api_url}
XRAY_DOMAIN=${XRAY_DOMAIN}
XRAY_API_HTTPS_PORT=${api_https_port}
XRAY_TRANSPORT_MODE=${XRAY_TRANSPORT_MODE:-tls}
XRAY_ACCEPT_PROXY_PROTOCOL=${XRAY_ACCEPT_PROXY_PROTOCOL:-true}
XRAY_MANAGER_HOST_PORT=${XRAY_MANAGER_HOST_PORT:-5012}
XRAY_XHTTP_ENABLED=${XRAY_XHTTP_ENABLED:-true}
XRAY_XHTTP_PORT=${XRAY_XHTTP_PORT:-2053}
XRAY_XHTTP_PATH=${XRAY_XHTTP_PATH:-/api/v1/update}
XRAY_XHTTP_MODE=${XRAY_XHTTP_MODE:-auto}
XRAY_CLIENT_LINK_TRANSPORT=${XRAY_CLIENT_LINK_TRANSPORT:-xhttp}
XRAY_HOST_GATEWAY=${gw}
XRAY_DNS1=${pihole_dns}
XRAY_DNS2=${pihole_dns}
# Pi-hole web UI listens on TCP tun .1 (PIHOLE_DNS_IP), not docker0 — never 172.17.0.1:8080
XRAY_PIHOLE_BASE_URL=http://${pihole_dns}:${PIHOLE_WEB_PORT:-8080}
XRAY_DNS_IDENTITY_ENABLED=${XRAY_DNS_IDENTITY_ENABLED:-true}
XRAY_DNS_IDENTITY_SUBNET=${XRAY_DNS_IDENTITY_SUBNET}
XRAY_DNS_IDENTITY_IFACE=eth0
XRAY_PIHOLE_CLIENT_SUBNET_PREFIX=${prefix}
XRAY_PIHOLE_EXCLUDE_PREFIXES=${exclude}
PIHOLE_WEBPASSWORD=${PIHOLE_WEBPASSWORD}
NGINX_CERTBOT_CONF=${nginx_certs}
EOF
  # render-config.sh routes these to a blackhole by SNI — reaches shared-CDN hosts the firewall cannot.
  if is_true "$BLOCKLIST_ENABLED"; then
    cat >>"$dest" <<EOF
XRAY_BLOCKLIST_DOMAINS_FILE=/data/blocklist/ru-services.domains
XRAY_BLOCKLIST_CIDRS_FILE=/data/blocklist/ru-services.cidrs
EOF
  fi
}

ensure_xray_network() {
  # Must carry compose labels — bare `docker network create` then `compose up` fails with
  # "network … incorrect label com.docker.compose.network" (blocks start_xray every fresh host).
  local name=datagate-monitor-xray_xray_network
  if docker network inspect "$name" >/dev/null 2>&1; then
    local label
    label="$(docker network inspect -f '{{index .Labels "com.docker.compose.network"}}' "$name" 2>/dev/null || true)"
    if [[ "$label" != "xray_network" ]]; then
      info "Recreating $name with compose labels (was unlabeled)"
      docker network rm "$name" >/dev/null 2>&1 || true
    else
      return 0
    fi
  fi
  docker network create \
    --label com.docker.compose.project=datagate-monitor-xray \
    --label com.docker.compose.network=xray_network \
    "$name" >/dev/null
}

write_nginx_compose() {
  local home="$1"
  if is_true "${INSTALL_XRAY:-false}"; then
    cp "$TEMPLATES/nginx-docker/docker-compose.yml" "$home/nginx-docker/docker-compose.yml"
  else
    cat >"$home/nginx-docker/docker-compose.yml" <<'EOF'
services:
  nginx:
    image: nginx:stable
    container_name: nginx
    restart: unless-stopped
    ulimits:
      nofile:
        soft: 65535
        hard: 65535
    ports:
      - "80:80"
      - "443:443"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/conf.d:/etc/nginx/conf.d:ro
      - ./nginx/stream.d:/etc/nginx/stream.d:ro
      - ./nginx/logs:/var/log/nginx
      - ./certbot/www:/var/www/certbot
      - ./certbot/conf:/etc/letsencrypt

  certbot:
    image: certbot/certbot
    container_name: certbot
    volumes:
      - ./certbot/www:/var/www/certbot
      - ./certbot/conf:/etc/letsencrypt
EOF
  fi
  write_nginx_env "$home/nginx-docker/.env"
}

render_stacks() {
  local home="$INSTALL_HOME"
  info "Rendering stacks under $home"

  mkdir -p \
    "$home/pi-hole/etc-pihole" \
    "$home/pi-hole/etc-dnsmasq.d" \
    "$home/nginx-docker/nginx/conf.d" \
    "$home/nginx-docker/nginx/stream.d" \
    "$home/nginx-docker/nginx/logs" \
    "$home/nginx-docker/certbot/www" \
    "$home/nginx-docker/certbot/conf" \
    "$home/host"

  if want_tcp; then
    mkdir -p "$home/openvpn-tcp-wss/data"
    cp "$TEMPLATES/openvpn-tcp-wss/docker-compose.yml" "$home/openvpn-tcp-wss/docker-compose.yml"
    cp "$TEMPLATES/openvpn-wss-entrypoint.sh" "$home/openvpn-tcp-wss/wss-entrypoint.sh"
    write_openvpn_tcp_env "$home/openvpn-tcp-wss/.env"
  fi

  if want_udp; then
    mkdir -p "$home/openvpn-udp-wss/data"
    cp "$TEMPLATES/openvpn-udp-wss/docker-compose.yml" "$home/openvpn-udp-wss/docker-compose.yml"
    cp "$TEMPLATES/openvpn-wss-entrypoint.sh" "$home/openvpn-udp-wss/wss-entrypoint.sh"
    write_openvpn_udp_env "$home/openvpn-udp-wss/.env"
  fi

  write_pihole_compose "$home/pi-hole/docker-compose.yml"
  write_pihole_env "$home/pi-hole/.env"
  write_pihole_blocklist "$home/pi-hole/etc-dnsmasq.d/10-datagate-blocklist.conf"
  render_file "$TEMPLATES/pi-hole/wait-tun0-and-start.sh" "$home/pi-hole/wait-tun0-and-start.sh"
  chmod +x "$home/pi-hole/wait-tun0-and-start.sh"

  write_nginx_compose "$home"
  if tls_certs_ready "$home"; then
    info "TLS certs found — rendering full nginx config"
    write_full_nginx "$home/nginx-docker/nginx/conf.d" "$home/nginx-docker/nginx/stream.d"
  else
    write_http_only_nginx "$home/nginx-docker/nginx/conf.d" "$home/nginx-docker/nginx/stream.d"
  fi

  write_host_env "$home/host/.env"
  sync_blocklist_assets
  if want_tcp; then
    sync_pihole_after_tcp_assets
  else
    sync_dns_dummy_assets
  fi
  cp "$ENV_FILE" "$home/site.env"
  cp "$ENV_FILE" "$home/site.env.installed"

  if is_true "${INSTALL_XRAY:-false}"; then
    mkdir -p "$home/datagate-monitor-xray/data/xray_data"
    cp "$TEMPLATES/xray/docker-compose.yml" "$home/datagate-monitor-xray/docker-compose.yml"
    write_xray_env "$home/datagate-monitor-xray/.env"
    mkdir -p "$home/datagate-monitor-xray/data/xray_data/blocklist"
    cp "$ROOT_DIR/blocklist/ru-services.domains" "$ROOT_DIR/blocklist/ru-services.cidrs" \
      "$home/datagate-monitor-xray/data/xray_data/blocklist/"
    sync_xray_dns_route_assets
  fi

  if [[ -n "${SUDO_USER:-}" ]] && id "$SUDO_USER" >/dev/null 2>&1; then
    chown -R "$SUDO_USER:$SUDO_USER" \
      "$home/pi-hole" "$home/nginx-docker" "$home/host" \
      "$home/site.env" "$home/site.env.installed" 2>/dev/null || true
    want_tcp && chown -R "$SUDO_USER:$SUDO_USER" "$home/openvpn-tcp-wss" 2>/dev/null || true
    want_udp && chown -R "$SUDO_USER:$SUDO_USER" "$home/openvpn-udp-wss" 2>/dev/null || true
    if is_true "${INSTALL_XRAY:-false}" && [[ -d "$home/datagate-monitor-xray" ]]; then
      chown -R "$SUDO_USER:$SUDO_USER" "$home/datagate-monitor-xray" 2>/dev/null || true
    fi
  fi

  # nginx in container runs as uid 101 — needs write access to log dir
  chmod 0777 "$home/nginx-docker/nginx/logs"
  chmod 0755 "$home/nginx-docker/certbot/www"

  info "Rendered$(want_tcp && echo ' openvpn-tcp-wss /')$(want_udp && echo ' openvpn-udp-wss /') pi-hole / nginx-docker / host$(want_xray && echo ' / xray')"
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    info "Docker already installed"
    return
  fi
  info "Installing Docker (official convenience script)"
  curl -fsSL https://get.docker.com | sh
  systemctl enable --now docker
  if id "${SUDO_USER:-}" >/dev/null 2>&1; then
    usermod -aG docker "$SUDO_USER" || true
  fi
}

setup_ufw() {
  info "Applying UFW + sysctl"
  export INSTALLER_SSH_CLIENT_IP
  ENV_FILE="$INSTALL_HOME/host/.env" "$SCRIPT_DIR/setup-host-ufw.sh"
}

setup_ovpn_dco() {
  want_openvpn || return 0
  if ! is_true "${TCP_DCO:-true}" && ! is_true "${UDP_DCO:-true}"; then
    info "DCO disabled for both stacks — skip host module"
    return 0
  fi
  info "Ensuring OpenVPN DCO kernel module on host"
  "$SCRIPT_DIR/setup-ovpn-dco.sh" || warn "DCO module setup failed — OpenVPN will use userspace crypto"
}

wait_openvpn_up() {
  info "Waiting for OpenVPN containers (first boot can take a few minutes for PKI)..."
  local i=0
  while [[ $i -lt 150 ]]; do
    local tcp_state="skipped" udp_running="skipped"
    if want_tcp; then
      tcp_state="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' openvpn-tcp-wss 2>/dev/null || echo missing)"
    fi
    if want_udp; then
      udp_running="$(docker inspect --format '{{.State.Running}}' openvpn-udp-wss 2>/dev/null || echo false)"
    fi
    if [[ "$tcp_state" =~ ^(healthy|running|skipped)$ ]] && [[ "$udp_running" =~ ^(true|skipped)$ ]]; then
      # Prefer healthy; accept running after enough time if healthcheck not ready
      if [[ "$tcp_state" != "running" ]] || [[ $i -gt 30 ]]; then
        info "OpenVPN is up (tcp=$tcp_state udp=$udp_running)"
        return 0
      fi
    fi
    sleep 2
    i=$((i + 1))
  done
  warn "OpenVPN not healthy yet — check: docker ps -a && docker logs openvpn-tcp-wss"
  docker ps -a --filter name=openvpn || true
}

start_openvpn() {
  want_openvpn || { info "OpenVPN not selected for this host — skip"; return 0; }
  info "Starting OpenVPN ($(want_tcp && echo 'TCP ')$(want_udp && echo 'UDP ')— separate stacks)"
  if want_tcp; then
    (cd "$INSTALL_HOME/openvpn-tcp-wss" && docker compose pull && docker compose up -d)
  fi
  if want_udp; then
    (cd "$INSTALL_HOME/openvpn-udp-wss" && docker compose pull && docker compose up -d)
  fi
  wait_openvpn_up
}

# A reinstall with fewer protocols stops the stacks that are no longer selected. Their data dirs (PKI) stay.
stop_unselected_stacks() {
  local name dir
  # Pi-hole sits in the TCP container's netns: release it (and stop the watcher that would re-join it) before
  # TCP goes away. start_pihole recreates it in the host netns.
  if ! want_tcp && docker inspect openvpn-tcp-wss >/dev/null 2>&1; then
    systemctl disable --now datagate-pihole-after-tcp.service >/dev/null 2>&1 || true
    docker rm -f datagate-pihole >/dev/null 2>&1 || true
  fi
  for name in openvpn-tcp-wss openvpn-udp-wss datagate-monitor-xray; do
    case "$name" in
      openvpn-tcp-wss) want_tcp && continue ;;
      openvpn-udp-wss) want_udp && continue ;;
      datagate-monitor-xray) want_xray && continue ;;
    esac
    dir="$INSTALL_HOME/$name"
    if [[ -f "$dir/docker-compose.yml" ]]; then
      info "Stopping $name (not selected for this host; data kept in $dir)"
      (cd "$dir" && docker compose down) || warn "could not stop $name — docker compose down in $dir"
    elif docker inspect "$name" >/dev/null 2>&1; then
      info "Removing container $name (not selected for this host)"
      docker rm -f "$name" >/dev/null || warn "could not remove container $name"
    fi
  done
  if ! want_xray; then
    systemctl disable --now datagate-xray-dns-route.service >/dev/null 2>&1 || true
  fi
  # TCP tun takes over PIHOLE_DNS_IP from the dummy interface of an earlier install without TCP.
  if want_tcp; then
    systemctl disable --now datagate-dns-dummy.service >/dev/null 2>&1 || true
  fi
}

start_pihole() {
  if want_tcp; then
    info "Starting Pi-hole (joins openvpn-tcp-wss netns; force-recreate so join uses current TCP id)"
  else
    # The after-tcp watcher would recreate Pi-hole into a TCP netns that no longer exists.
    systemctl disable --now datagate-pihole-after-tcp.service >/dev/null 2>&1 || true
    install_dns_dummy_service
    info "Starting Pi-hole (host netns, DNS on ${DNS_DUMMY_DEV} ${PIHOLE_DNS_IP})"
  fi
  (cd "$INSTALL_HOME/pi-hole" && docker compose up -d --force-recreate)
  local i st
  info "waiting for datagate-pihole healthy/running (up to 180s)"
  for ((i = 0; i < 180; i++)); do
    st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' datagate-pihole 2>/dev/null || echo missing)"
    if [[ "$st" == "healthy" || "$st" == "running" ]]; then
      info "datagate-pihole $st"
      break
    fi
    sleep 1
  done
  if ! docker inspect --format '{{.State.Running}}' datagate-pihole 2>/dev/null | grep -q true; then
    warn "Pi-hole not running — check: docker logs datagate-pihole"
    want_tcp && warn "Fix: sudo systemctl restart datagate-pihole-after-tcp.service"
  fi
  if want_tcp; then
    install_pihole_after_tcp_service || warn "datagate-pihole-after-tcp.service not installed"
  fi
}

install_dns_dummy_service() {
  sync_dns_dummy_assets
  local unit_src="$INSTALL_HOME/host/datagate-dns-dummy.service"
  if grep -qE '__[A-Z0-9_]+__' "$unit_src"; then
    die "unresolved placeholders in $unit_src"
  fi
  info "Enabling systemd unit datagate-dns-dummy (${DNS_DUMMY_DEV} ${PIHOLE_DNS_IP}/32 for Pi-hole)"
  install -m 0644 "$unit_src" /etc/systemd/system/datagate-dns-dummy.service
  systemctl daemon-reload
  systemctl enable datagate-dns-dummy.service
  systemctl restart datagate-dns-dummy.service || die "datagate-dns-dummy.service failed — systemctl status datagate-dns-dummy"
}

install_pihole_after_tcp_service() {
  sync_pihole_after_tcp_assets
  local unit_src="$INSTALL_HOME/host/datagate-pihole-after-tcp.service"
  [[ -f "$unit_src" ]] || return 1
  [[ -x "$INSTALL_HOME/host/watch-pihole-after-tcp.sh" ]] || return 1
  [[ -x "$INSTALL_HOME/host/recreate-pihole-after-tcp.sh" ]] || return 1
  if grep -qE '__[A-Z0-9_]+__' "$unit_src"; then
    warn "unresolved placeholders in $unit_src — fix INSTALL_HOME in site.env and re-render"
    return 1
  fi
  info "Enabling systemd unit datagate-pihole-after-tcp (boot + docker events on TCP start)"
  # Drop any prior mask (empty/failed install left unit masked on some hosts)
  systemctl unmask datagate-pihole-after-tcp.service >/dev/null 2>&1 || true
  # Stop old oneshot RemainAfterExit unit before replacing with long-running watcher
  systemctl stop datagate-pihole-after-tcp.service >/dev/null 2>&1 || true
  install -m 0644 "$unit_src" /etc/systemd/system/datagate-pihole-after-tcp.service
  systemctl daemon-reload
  systemctl enable datagate-pihole-after-tcp.service
  systemctl restart datagate-pihole-after-tcp.service \
    || warn "datagate-pihole-after-tcp.service start failed — run: sudo systemctl status datagate-pihole-after-tcp"
}

start_nginx() {
  info "Starting nginx (HTTP for ACME)"
  if is_true "${INSTALL_XRAY:-false}"; then
    ensure_xray_network
  fi
  (cd "$INSTALL_HOME/nginx-docker" && docker compose up -d nginx)
}

# One certificate directory per domain (nginx expects live/<domain>/...)
issue_cert_for_domain() {
  local domain="$1"
  info "Certbot: $domain"
  (cd "$INSTALL_HOME/nginx-docker" && docker compose run --rm certbot certonly \
    --webroot -w /var/www/certbot \
    --cert-name "$domain" \
    -d "$domain" \
    --email "$CERTBOT_EMAIL" \
    --agree-tos \
    --no-eff-email \
    --non-interactive \
    --keep-until-expiring)
}

issue_certs() {
  info "Issuing Let's Encrypt certs (one cert per domain)"
  : "${CERTBOT_EMAIL:?CERTBOT_EMAIL required for ISSUE_CERTS}"

  local domains
  mapfile -t domains < <(wss_domains)
  if [[ -n "${HFS_DOMAIN:-}" ]]; then
    domains+=("$HFS_DOMAIN")
  fi
  if is_true "${INSTALL_XRAY:-false}" && [[ -n "${XRAY_DOMAIN:-}" ]]; then
    domains+=("$XRAY_DOMAIN")
  fi

  local d
  for d in "${domains[@]}"; do
    issue_cert_for_domain "$d" || die "certbot failed for $d — check DNS A-record → $PUBLIC_IP and port 80"
  done

  # Xray upstream must exist before nginx stream SNI config is applied
  if is_true "${INSTALL_XRAY:-false}"; then
    start_xray
  fi

  apply_full_nginx_tls
}

apply_full_nginx_tls() {
  write_full_nginx "$INSTALL_HOME/nginx-docker/nginx/conf.d" "$INSTALL_HOME/nginx-docker/nginx/stream.d"
  (cd "$INSTALL_HOME/nginx-docker" && docker compose up -d nginx)
  (cd "$INSTALL_HOME/nginx-docker" && docker compose exec nginx nginx -t) \
    || die "nginx config test failed after certs"
  (cd "$INSTALL_HOME/nginx-docker" && docker compose exec nginx nginx -s reload) \
    || (cd "$INSTALL_HOME/nginx-docker" && docker compose restart nginx)
  info "TLS enabled — nginx reloaded (WSS on :8443 via SNI :443)"
}

start_xray() {
  info "Starting Xray (needs certs already issued)"
  ensure_xray_network
  local cert="$INSTALL_HOME/nginx-docker/certbot/conf/live/${XRAY_DOMAIN}/fullchain.pem"
  if [[ ! -f "$cert" ]]; then
    die "missing $cert — issue certs before starting Xray"
  fi
  (cd "$INSTALL_HOME/datagate-monitor-xray" && docker compose pull && docker compose up -d)
  sync_xray_dns_route_assets
  sleep 2
  setup_xray_dns_identity_route || warn "xray identity route not applied — run: sudo systemctl start datagate-xray-dns-route.service"
  install_xray_dns_route_service
}

setup_xray_dns_identity_route() {
  [[ -n "${XRAY_DNS_IDENTITY_SUBNET:-}" ]] || return 0
  local route_env="$ENV_FILE"
  if [[ -f "${INSTALL_HOME}/site.env" ]]; then
    route_env="${INSTALL_HOME}/site.env"
  fi
  local route_script="${INSTALL_HOME}/host/setup-xray-dns-identity-route.sh"
  if [[ ! -x "$route_script" ]]; then
    warn "missing $route_script — re-run render or install"
    return 1
  fi
  ENV_FILE="$route_env" "$route_script"
}

install_xray_dns_route_service() {
  [[ -n "${XRAY_DNS_IDENTITY_SUBNET:-}" ]] || return 0
  sync_xray_dns_route_assets
  local unit_src="$INSTALL_HOME/host/datagate-xray-dns-route.service"
  [[ -f "$unit_src" ]] || return 0
  if grep -qE '__[A-Z0-9_]+__' "$unit_src"; then
    warn "unresolved placeholders in $unit_src — fix INSTALL_HOME in site.env and re-render"
    return 0
  fi
  info "Enabling systemd unit for Xray DNS identity route (survives reboot)"
  install -m 0644 "$unit_src" /etc/systemd/system/datagate-xray-dns-route.service
  systemctl daemon-reload
  systemctl enable datagate-xray-dns-route.service
  systemctl start datagate-xray-dns-route.service || warn "datagate-xray-dns-route.service start failed — xray may not be up yet"
}

print_summary() {
  cat <<EOF

======== DONE ========
Stacks under: $INSTALL_HOME

$(want_udp && echo "  OpenVPN UDP WSS: https://${UDP_WSS_DOMAIN}/  (SNI → :8443 → host :${UDP_API_PORT})")
$(want_tcp && echo "  OpenVPN TCP WSS: https://${TCP_WSS_DOMAIN}/  (SNI → :8443 → host :${TCP_API_PORT})")
  Pi-hole DNS:     ${PIHOLE_DNS_IP}:53 (VPN clients, on ${PIHOLE_PRIMARY_DEV})
  Pi-hole admin:   http://${PIHOLE_DNS_IP}:${PIHOLE_WEB_PORT}/ (via VPN)
$(if want_tcp; then
  echo "  Pi-hole reboot:  systemd datagate-pihole-after-tcp.service (watcher: boot + TCP start events)"
else
  echo "  Pi-hole address: systemd datagate-dns-dummy.service (${DNS_DUMMY_DEV}, created before docker)"
fi)
EOF
  if is_true "${INSTALL_XRAY:-false}"; then
    cat <<EOF
  Xray VLESS:      ${XRAY_DOMAIN}:443 (SNI → container)
  Xray ApiUrl:     https://${XRAY_DOMAIN}:${XRAY_API_HTTPS_PORT:-9443}
  Xray DNS identity subnet: ${XRAY_DNS_IDENTITY_SUBNET}
  Xray DNS route:  systemd datagate-xray-dns-route.service (reboot-safe)
  Xray Pi-hole:    BaseURL http://${PIHOLE_DNS_IP}:${PIHOLE_WEB_PORT:-8080}  prefix ${XRAY_PIHOLE_CLIENT_SUBNET_PREFIX}  (password = PIHOLE_WEBPASSWORD)
EOF
  fi
  cat <<EOF

Self-announce ApiUrl (written into each stack .env as PUBLIC_API_URL):
$(want_udp && echo "  - UDP  OpenVPN  https://${UDP_WSS_DOMAIN}/")
$(want_tcp && echo "  - TCP  OpenVPN  https://${TCP_WSS_DOMAIN}/")
$(is_true "${INSTALL_XRAY:-false}" && echo "  - Xray          https://${XRAY_DOMAIN}:${XRAY_API_HTTPS_PORT:-9443}/")
  Approve pending discoveries as-is; Pi-hole settings are imported and applied automatically.
  Pi-hole credentials are sent only to an HTTPS backend (loopback HTTP is allowed for local development).
  - Backend: ${BACKEND__BASEURL}
  - Subnets: TCP ${TCP_VPN_SUBNET}/24 , UDP ${UDP_VPN_SUBNET}/24
$(is_true "${INSTALL_XRAY:-false}" && echo "  - Identity: ${XRAY_DNS_IDENTITY_SUBNET}")

Useful:
  docker ps -a
$(want_tcp && echo "  cd $INSTALL_HOME/openvpn-tcp-wss && docker compose logs -f --tail=100")
$(want_udp && echo "  cd $INSTALL_HOME/openvpn-udp-wss && docker compose logs -f --tail=100")
  cd $INSTALL_HOME/pi-hole && docker compose logs -f --tail=100
  cd $INSTALL_HOME/nginx-docker && docker compose logs -f --tail=50

Post-install verify:
  sudo ENV_FILE=$INSTALL_HOME/site.env $SCRIPT_DIR/post-install-check.sh
EOF
}

run_post_install_check() {
  [[ "$RENDER_ONLY" -eq 1 ]] && return 0
  [[ "$SKIP_START" -eq 1 ]] && return 0
  is_true "${START_STACKS:-true}" || return 0
  info "Running post-install checks"
  if ENV_FILE="${INSTALL_HOME}/site.env" "$SCRIPT_DIR/post-install-check.sh"; then
    info "post-install checks passed"
  else
    die "post-install checks failed — fix before dashboard registration (see output above)"
  fi
}

main() {
  if [[ "$RENDER_ONLY" -eq 0 ]]; then
    [[ "$(id -u)" -eq 0 ]] || die "run as root: sudo $0 ..."
    # unattended-upgrades often holds the dpkg lock on a fresh VM: make every apt-get wait for it instead of failing.
    echo 'DPkg::Lock::Timeout "900";' > /etc/apt/apt.conf.d/90dgsc-lock-wait
  fi

  if [[ "$WIZARD" -eq 1 ]] || [[ ! -f "$ENV_FILE" ]]; then
    if [[ ! -f "$ENV_FILE" ]]; then
      info "No site.env found — starting wizard"
      WIZARD=1
    fi
  fi
  [[ "$WIZARD" -eq 1 ]] && run_wizard
  load_env
  preflight

  if [[ "$RENDER_ONLY" -eq 0 ]] && want_openvpn && is_true "$OPENVPN_WSS_ONLY"; then
    if [[ "$SKIP_UFW" -ne 0 ]] || ! is_true "${SETUP_UFW:-true}"; then
      die "OPENVPN_WSS_ONLY=true requires SETUP_UFW=true and no --skip-ufw (manager APIs need firewall protection)"
    fi
  fi

  render_stacks
  [[ "$RENDER_ONLY" -eq 1 ]] && { info "render-only complete → $INSTALL_HOME"; exit 0; }

  if [[ "$SKIP_DOCKER" -eq 0 ]] && is_true "${INSTALL_DOCKER:-true}"; then
    ensure_docker
  fi

  if [[ "$SKIP_UFW" -eq 0 ]] && is_true "${SETUP_UFW:-true}"; then
    setup_ufw
  fi

  if systemctl is-active --quiet docker 2>/dev/null; then
    install_blocklist_service
  else
    warn "Docker is not running — blocklist firewall rules not applied (re-run the installer later)"
  fi

  if [[ "$SKIP_START" -eq 0 ]] && is_true "${START_STACKS:-true}"; then
    stop_unselected_stacks
    setup_ovpn_dco
    # Order: OpenVPN → Pi-hole → nginx(HTTP, no Xray upstream) → certs
    #        → start Xray → full nginx (SNI + WSS)
    start_openvpn
    start_pihole
    start_nginx
    if [[ "$SKIP_CERTS" -eq 0 ]] && is_true "${ISSUE_CERTS:-true}"; then
      issue_certs
    else
      warn "skipped certs — nginx is HTTP-only; later: re-run without --skip-certs"
      if is_true "${INSTALL_XRAY:-false}"; then
        warn "Xray skipped because certs were skipped (Xray needs TLS files)"
      fi
    fi
  fi

  run_post_install_check
  print_summary
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  main
fi
