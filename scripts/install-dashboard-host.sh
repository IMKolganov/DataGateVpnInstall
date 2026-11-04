#!/usr/bin/env bash
# Install the Monitor dashboard, Telegram bot and landing on an encrypted Ubuntu host.
# Uses the SAME SSH/console/observability scripts and tang-gate bundle as VPN hosts.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATES="$ROOT_DIR/templates/dashboard"
env_file="$ROOT_DIR/dashboard.env"
mode=full
bundle_dir=""
secret_dir=""

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
need_value() { [[ -n "${2:-}" && "$2" != --* ]] || die "$1 needs a value"; }
usage() {
  cat <<'EOF'
sudo ./scripts/install-dashboard-host.sh --env /dev/shm/dashboard.env [options]
  --prepare-only          Encrypt empty data device; configure Docker, UFW, SSH/console 2FA and monitoring
  --deploy-only           Deploy apps on an already prepared, unlocked host
  --render-only           Write app configs only; no root, host changes, network requests or containers
  --tang-bundle-dir DIR   Extracted service bundle from tang-gate (needed for the FIRST encryption)

Default: prepare, then deploy. No live server is contacted by --render-only.
DATA_DEVICE must be an empty disk/partition. No root partition is resized or erased.
First encryption uses tang-gate's interactive device confirmation and offline recovery passphrase.
See DASHBOARD.md for the two-stage installation and secret-file options.
EOF
}
cleanup() { [[ -z "$secret_dir" ]] || rm -rf -- "$secret_dir"; return 0; }
trap cleanup EXIT

while (($#)); do
  case "$1" in
    --env) need_value "$1" "${2:-}"; env_file="$2"; shift 2 ;;
    --tang-bundle-dir) need_value "$1" "${2:-}"; bundle_dir="$2"; shift 2 ;;
    --prepare-only|--prepare-runtime-only|--deploy-only|--render-only|--render-draft-only)
      [[ "$mode" == full ]] || die "choose only one mode"
      mode="${1#--}"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

required() {
  local k v
  for k in "$@"; do
    v="${!k:-}"
    [[ -n "$v" && "$v" != *YOUR_* && "$v" != *CHANGE_ME* && "$v" != *example.com* ]] \
      || die "fill $k in dashboard.env"
    [[ "$v" != *$'\n'* && "$v" != *$'\r'* ]] || die "$k must be a single line"
  done
}
ipv4() {
  local n parts
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r -a parts <<<"$1"
  for n in "${parts[@]}"; do [[ ${#n} -le 3 ]] && ((10#$n <= 255)) || return 1; done
}
domain() {
  local label labels
  [[ ${#1} -le 253 && "$1" == *.* && "$1" != *example.com* ]] || return 1
  IFS=. read -r -a labels <<<"$1"
  for label in "${labels[@]}"; do
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
  done
  [[ "$1" != *. ]]
}

load_config() {
  local key
  [[ -f "$env_file" ]] || die "missing $env_file (copy dashboard.env.example)"
  env_file="$(realpath "$env_file")"
  # dashboard.env is a TRUSTED Bash config, like site.env. Do not use untrusted env files.
  # shellcheck disable=SC1090
  source "$env_file"
  : "${INSTALL_HOME:=/srv/data/datagate}"
  : "${DATA_DEVICE:=/dev/disk/by-partlabel/dgsc-data}"
  : "${TG_DOMAIN:=}"
  : "${DASHBOARD_DOMAIN:=${API_DOMAIN:-}}"
  : "${LANDING_DOMAINS:=}"
  : "${WAZUH_AGENT_NAME:=dg-dashboard}"
  : "${WAZUH_VERSION:=4.14.5}"
  : "${NODE_EXPORTER_VERSION:=1.8.2}"
  : "${NODE_EXPORTER_PORT:=9100}"
  : "${BACKEND_IMAGE:=imkolganov/datagate-monitor-backend:latest}"
  : "${FRONTEND_IMAGE:=imkolganov/datagate-monitor-frontend:latest}"
  : "${BOT_IMAGE:=imkolganov/datagate-monitor-telegrambot:latest}"
  : "${REDIS_IMAGE:=redis:7-alpine}"
  : "${NGINX_IMAGE:=nginx:stable-alpine}"
  : "${CERTBOT_IMAGE:=certbot/certbot:latest}"
  : "${LANDING_GIT_URL:=https://github.com/IMKolganov/datagate-landing.git}"
  : "${LANDING_GIT_REF:=main}"
  [[ "$INSTALL_HOME" =~ ^/[A-Za-z0-9_./-]+$ && "$INSTALL_HOME" != / ]] || die "invalid INSTALL_HOME"
  INSTALL_HOME="$(realpath -m "$INSTALL_HOME")"
  if [[ "$mode" != render-only && "$mode" != render-draft-only ]]; then
    [[ "$INSTALL_HOME" == /srv/data/* ]] || die "INSTALL_HOME must be below encrypted /srv/data"
  fi
  required PUBLIC_IP ADMIN_SSH_IP ADMIN_USER WAZUH_MANAGER PROMETHEUS_IP
  for key in PUBLIC_IP ADMIN_SSH_IP PROMETHEUS_IP; do
    ipv4 "${!key}" || die "invalid $key IPv4"
  done
  [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ && "$ADMIN_USER" != root ]] || die "invalid ADMIN_USER"
  [[ "$WAZUH_MANAGER" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] || die "invalid WAZUH_MANAGER"
  [[ "$WAZUH_AGENT_NAME" =~ ^[a-z0-9][a-z0-9._-]{0,62}$ ]] || die "invalid WAZUH_AGENT_NAME"
  [[ "$NODE_EXPORTER_PORT" =~ ^[0-9]{1,5}$ ]] || die "invalid NODE_EXPORTER_PORT"
  ((10#$NODE_EXPORTER_PORT >= 1024 && 10#$NODE_EXPORTER_PORT <= 65535)) || die "invalid NODE_EXPORTER_PORT"
  [[ "$WAZUH_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$NODE_EXPORTER_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "invalid agent/exporter version"
  [[ "$mode" == prepare-only || "$mode" == prepare-runtime-only ]] && return 0
  if [[ "$mode" == render-draft-only ]]; then
    : "${API_DOMAIN:=}" "${DB_CONNECTION_STRING_DATAGATE:=}" "${JWT_SECRET:=}"
    : "${TELEGRAMBOT_BOT_TOKEN:=}" "${DASHBOARDAPI_CLIENTID:=}" "${DASHBOARDAPI_CLIENTSECRET:=}"
    read -r -a landing_domains <<<"$LANDING_DOMAINS"
    return 0
  fi
  required CERTBOT_EMAIL API_DOMAIN DB_CONNECTION_STRING_DATAGATE JWT_SECRET
  [[ "$CERTBOT_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "invalid CERTBOT_EMAIL"
  [[ ${#JWT_SECRET} -ge 32 ]] || die "JWT_SECRET needs at least 32 characters"
  domain "$API_DOMAIN" || die "invalid API_DOMAIN"
  domain "$DASHBOARD_DOMAIN" || die "invalid DASHBOARD_DOMAIN"
  local d seen=" $API_DOMAIN "
  if [[ "$DASHBOARD_DOMAIN" != "$API_DOMAIN" ]]; then seen+="$DASHBOARD_DOMAIN "; fi
  read -r -a landing_domains <<<"$LANDING_DOMAINS"
  for d in "${landing_domains[@]}" ${TG_DOMAIN:+"$TG_DOMAIN"}; do
    domain "$d" || die "invalid domain: $d"
    [[ "$seen" != *" $d "* ]] || die "domain used twice: $d"
    seen+="$d "
  done
  if [[ -n "$TG_DOMAIN" ]]; then
    required TELEGRAMBOT_BOT_TOKEN DASHBOARDAPI_CLIENTID DASHBOARDAPI_CLIENTSECRET
  fi
  for key in BACKEND_IMAGE FRONTEND_IMAGE BOT_IMAGE REDIS_IMAGE NGINX_IMAGE CERTBOT_IMAGE; do
    [[ "${!key}" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]+$ ]] || die "invalid $key"
  done
  [[ "$LANDING_GIT_URL" == https://* && "$LANDING_GIT_URL" != *[[:space:]]* ]] || die "LANDING_GIT_URL must use HTTPS"
  [[ "$LANDING_GIT_REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]*$ ]] || die "invalid LANDING_GIT_REF"
  # Optional application settings (mail/OAuth/telemetry/etc.) can be completed after deployment.
  # Only the required service settings above block installation.
}

assert_encrypted_mount() {
  local unlock_conf=/etc/tang-gate/unlock.conf
  [[ -f "$unlock_conf" ]] || die "host has no tang-gate configuration; run --prepare-only"
  mountpoint -q /srv/data || die "/srv/data is locked; approve on your PC: sudo tang-gate approve"
  # Check both the mounted mapper AND its underlying LUKS device against tang-gate's configuration.
  local configured_name configured_device configured_mount source mapper_device
  configured_name="$(sed -n 's/^NAME=//p' "$unlock_conf")"
  configured_device="$(sed -n 's/^DEVICE=//p' "$unlock_conf")"
  configured_mount="$(sed -n 's/^MOUNT=//p' "$unlock_conf")"
  [[ "$configured_name" =~ ^[A-Za-z0-9_-]+$ && "$configured_mount" == /srv/data ]] || die "unexpected tang-gate mount configuration"
  source="$(findmnt -nro SOURCE --mountpoint /srv/data)"
  [[ "$(readlink -f "$source")" == "$(readlink -f "/dev/mapper/$configured_name")" ]] || die "/srv/data is not the tang-gate mapper"
  cryptsetup isLuks "$configured_device" || die "configured data device is not LUKS"
  mapper_device="$(cryptsetup status "$configured_name" | awk '$1 == "device:" {print $2}')"
  [[ "$(readlink -f "$mapper_device")" == "$(readlink -f "$configured_device")" ]] || die "mounted mapper uses another device"
  local probe
  probe="$(realpath -m "$INSTALL_HOME")"
  [[ "$probe" == /srv/data/* ]] || die "INSTALL_HOME escapes the encrypted mount"
  while [[ ! -e "$probe" ]]; do probe="$(dirname "$probe")"; done
  [[ "$(findmnt -nro TARGET -T "$probe")" == /srv/data ]] || die "INSTALL_HOME escapes the encrypted mount"
}

ensure_encrypted_data() {
  if [[ -f /etc/tang-gate/unlock.conf ]]; then assert_encrypted_mount; return; fi
  [[ -n "$bundle_dir" ]] || die "first encryption needs --tang-bundle-dir (see DASHBOARD.md)"
  bundle_dir="$(realpath "$bundle_dir")"
  local f ovpn thp gate
  for f in bundle.env server/setup-server.sh server/tang-gate-unlock server/tang-gate-unlock.service; do
    [[ -f "$bundle_dir/$f" ]] || die "bundle missing $f"
  done
  ovpn="$(sed -n 's/^OVPN=//p' "$bundle_dir/bundle.env")"
  thp="$(sed -n 's/^TANG_THP=//p' "$bundle_dir/bundle.env")"
  gate="$(sed -n 's/^GATE_URL=//p' "$bundle_dir/bundle.env")"
  [[ "$ovpn" =~ ^[A-Za-z0-9._-]+\.ovpn$ && -f "$bundle_dir/$ovpn" ]] || die "invalid bundle OVPN"
  [[ "$thp" =~ ^[A-Za-z0-9_-]{16,128}$ && "$gate" =~ ^https?://[A-Za-z0-9.:-]+$ ]] || die "invalid bundle Tang pin/gate URL"
  [[ -b "$DATA_DEVICE" ]] || die "missing empty DATA_DEVICE=$DATA_DEVICE (attach a data disk or reserve dgsc-data at provisioning)"
  [[ -z "$(blkid -p -o value -s TYPE "$DATA_DEVICE" 2>/dev/null || true)" ]] || die "DATA_DEVICE already has a filesystem/signature; refusing to erase it"
  [[ -z "$(ls -A /srv/data 2>/dev/null)" ]] || die "/srv/data already contains files"
  local args=(--device "$DATA_DEVICE" --ovpn "$bundle_dir/$ovpn" --tang-thp "$thp" --gate-url "$gate"
    --mount /srv/data --start-units "containerd.service docker.service datagate-dashboard-services.target")
  # setup-server keeps its one-use recovery copy on tmpfs. It never prints a supplied recovery value.
  if [[ -n "${DATA_RECOVERY_FILE:-}" ]]; then
    [[ -f "$DATA_RECOVERY_FILE" ]] || die "DATA_RECOVERY_FILE not found"
    args+=(--recovery-file "$DATA_RECOVERY_FILE")
  fi
  info "Encrypting the empty data device with the VPN tang-gate setup (interactive device confirmation)"
  TMPDIR="$secret_dir" bash "$bundle_dir/server/setup-server.sh" "${args[@]}"
  assert_encrypted_mount
}

prepare_docker_storage() {
  local p target
  # No implicit migration of an existing Docker host. Both image stores and container logs must be encrypted.
  for p in docker containerd; do
    target="/srv/data/$p"
    if [[ -L "/var/lib/$p" ]]; then
      [[ "$(readlink -f "/var/lib/$p")" == "$target" ]] || die "/var/lib/$p points elsewhere"
    else
      [[ ! -e "/var/lib/$p" || -z "$(ls -A "/var/lib/$p")" ]] || die "/var/lib/$p is populated; use a fresh host (no automatic migration)"
    fi
  done
  # Custom storage roots would defeat the symlinks; accept only the managed/default roots.
  python3 - <<'PY'
import json, pathlib, tomllib
p = pathlib.Path('/etc/docker/daemon.json')
if p.exists():
    root = json.loads(p.read_text()).get('data-root', '/var/lib/docker')
    if root not in ('/var/lib/docker', '/srv/data/docker'):
        raise SystemExit('ERROR: custom Docker data-root; use a fresh host')
p = pathlib.Path('/etc/containerd/config.toml')
if p.exists():
    root = tomllib.loads(p.read_text()).get('root', '/var/lib/containerd')
    if root not in ('/var/lib/containerd', '/srv/data/containerd'):
        raise SystemExit('ERROR: custom containerd root; use a fresh host')
PY
  for p in docker containerd; do
    install -d -m 0711 "/srv/data/$p"
    if [[ ! -L "/var/lib/$p" ]]; then
      [[ ! -d "/var/lib/$p" ]] || rmdir "/var/lib/$p"
      ln -s "/srv/data/$p" "/var/lib/$p"
    fi
  done
  for p in docker.service docker.socket containerd.service datagate-dashboard-cert-renew.service datagate-dashboard-cert-renew.timer; do
    install -d -m 0755 "/etc/systemd/system/$p.d"
    printf '[Unit]\nConditionPathIsMountPoint=/srv/data\n' >"/etc/systemd/system/$p.d/tang-gate.conf"
  done
  cat >/etc/systemd/system/datagate-dashboard-services.target <<'EOF'
[Unit]
Description=DataGate dashboard services after encrypted disk unlock
ConditionPathIsMountPoint=/srv/data
Wants=containerd.service docker.service
After=containerd.service docker.service
EOF
  # Include new units when reusing an already encrypted VPN-style host.
  python3 - <<'PY'
import pathlib, re, shlex
p = pathlib.Path('/etc/tang-gate/unlock.conf')
text = p.read_text()
match = re.search(r'^START_UNITS=(.*)$', text, re.M)
units = shlex.split(match[1])[0].split() if match and shlex.split(match[1]) else []
for unit in ('containerd.service', 'docker.service', 'datagate-dashboard-services.target'):
    if unit not in units:
        units.append(unit)
if not all(re.fullmatch(r'[A-Za-z0-9@._:-]+\.(service|socket|target|timer)', u) for u in units):
    raise SystemExit('ERROR: invalid tang-gate start units')
line = 'START_UNITS="' + ' '.join(units) + '"'
p.write_text(re.sub(r'^START_UNITS=.*$', line, text, flags=re.M) if match else text + '\n' + line + '\n')
PY
  systemctl daemon-reload
}

ensure_docker() {
  if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
    info "Installing Docker using the same upstream installer as VPN hosts"
    curl -fsSL --retry 3 https://get.docker.com -o "$secret_dir/get-docker.sh"
    sh "$secret_dir/get-docker.sh"
  fi
  local version
  version="$(docker compose version --short)"; version="${version#v}"
  [[ "$(printf '%s\n' 2.30.0 "$version" | sort -V | head -n1)" == 2.30.0 ]] || die "Docker Compose >= 2.30 is required for raw env files"
  systemctl enable --now containerd.service docker.service
  [[ "$(realpath "$(docker info --format '{{.DockerRootDir}}')")" == /srv/data/docker ]] || die "Docker root is outside encrypted storage"
}

setup_firewall() {
  local ssh_port session_ip
  ssh_port="$(sshd -T | awk '$1 == "port" && !port {port=$2} END {print port}')"
  [[ "$ssh_port" =~ ^[0-9]+$ ]] || die "could not determine SSH port"
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow from "$ADMIN_SSH_IP" to any port "$ssh_port" proto tcp comment 'dashboard admin SSH'
  session_ip="${SSH_CONNECTION:-}"; session_ip="${session_ip%% *}"
  if [[ -n "$session_ip" && "$session_ip" != "$ADMIN_SSH_IP" ]]; then
    ufw allow from "$session_ip" to any port "$ssh_port" proto tcp comment 'current SSH session'
  fi
  ufw allow 80/tcp
  ufw allow 443/tcp
  ufw allow from "$PROMETHEUS_IP" to any port "$NODE_EXPORTER_PORT" proto tcp comment 'prometheus'
  ufw --force enable
}

prompt_password() {
  local label="$1" dest="$2" a b
  [[ -r /dev/tty ]] || die "$label needs a file option for non-interactive use"
  read -r -s -p "$label: " a </dev/tty; echo >/dev/tty
  read -r -s -p "Repeat $label: " b </dev/tty; echo >/dev/tty
  [[ "$a" == "$b" && ${#a} -ge 12 ]] || die "$label must match and have at least 12 characters"
  printf '%s\n' "$a" >"$dest"
}
setup_access_and_monitoring() {
  local args=(--user "$ADMIN_USER" --password-file "$secret_dir/admin-password" --skip-sshd)
  if [[ -n "${ADMIN_PASSWORD_FILE:-}" ]]; then
    install -m 0600 "$ADMIN_PASSWORD_FILE" "$secret_dir/admin-password"
  else
    prompt_password 'Admin sudo password' "$secret_dir/admin-password"
  fi
  if [[ -n "${ADMIN_PUBKEY_FILE:-}" ]]; then args+=(--pubkey "$ADMIN_PUBKEY_FILE"); fi
  if [[ -n "${ADMIN_TOTP_SECRET_FILE:-}" ]]; then args+=(--totp-secret-file "$ADMIN_TOTP_SECRET_FILE"); fi
  # Interactive QR/recovery-code enrolment happens before sshd is changed. Existing TOTP is preserved.
  bash "$SCRIPT_DIR/setup-host-ssh.sh" "${args[@]}"
  local admin_home
  admin_home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
  head -n1 "$admin_home/.google_authenticator" >"$secret_dir/totp"
  if [[ -n "${GRUB_PASSWORD_FILE:-}" ]]; then
    install -m 0600 "$GRUB_PASSWORD_FILE" "$secret_dir/grub-password"
  else
    prompt_password 'GRUB recovery password (save offline)' "$secret_dir/grub-password"
  fi
  args=(--user "$ADMIN_USER" --password-file "$secret_dir/admin-password"
    --totp-secret-file "$secret_dir/totp" --totp-out "$secret_dir/totp-enrolled"
    --grub-password-file "$secret_dir/grub-password"
    --wazuh-manager "$WAZUH_MANAGER" --agent-name "$WAZUH_AGENT_NAME" --wazuh-version "$WAZUH_VERSION"
    --node-exporter-version "$NODE_EXPORTER_VERSION" --prometheus-ip "$PROMETHEUS_IP" --node-exporter-port "$NODE_EXPORTER_PORT")
  if [[ -n "${WAZUH_PASSWORD_FILE:-}" ]]; then
    install -m 0600 "$WAZUH_PASSWORD_FILE" "$secret_dir/wazuh-password"
    args+=(--wazuh-password-file "$secret_dir/wazuh-password")
  fi
  bash "$SCRIPT_DIR/setup-observability.sh" "${args[@]}"
}

env_value() {
  [[ "$2" != *$'\n'* && "$2" != *$'\r'* ]] || die "$1 must be a single line"
  printf '%s=%s\n' "$1" "$2"
}
copy_env_keys() {
  local key
  for key in "$@"; do [[ ! -v "$key" ]] || env_value "$key" "${!key}"; done
}
render_template() {
  local template="$1" dest="$2" content key
  content="$(cat "$TEMPLATES/$template")"
  for key in BACKEND_IMAGE FRONTEND_IMAGE BOT_IMAGE REDIS_IMAGE NGINX_IMAGE CERTBOT_IMAGE; do
    content="${content//__${key}__/${!key}}"
  done
  printf '%s\n' "$content" >"$dest"
}
# nginx variables must stay literal in the generated config.
# shellcheck disable=SC2016
nginx_server() {
  local cert_name="$1" names="$2" upstream="$3" role="$4" out="$5"
  local cert_dir="$INSTALL_HOME/nginx-docker/certbot/conf/live/$cert_name"
  {
    printf 'server {\n    listen 80;\n    server_name %s;\n' "$names"
    cat <<'EOF'
    location /.well-known/acme-challenge/ { root /var/www/certbot; }
EOF
    if [[ -s "$cert_dir/fullchain.pem" && -s "$cert_dir/privkey.pem" ]]; then
      printf '    location / { return 301 https://$host$request_uri; }\n}\n'
      # HTTP/2 as on the old host: clients (OkHttp) read bodies via its reader thread, not the caller's.
      printf 'server {\n    listen 443 ssl;\n    http2 on;\n    server_name %s;\n' "$names"
      printf '    ssl_certificate /etc/letsencrypt/live/%s/fullchain.pem;\n' "$cert_name"
      printf '    ssl_certificate_key /etc/letsencrypt/live/%s/privkey.pem;\n' "$cert_name"
      cat <<'EOF'
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header X-Content-Type-Options nosniff always;
    resolver 127.0.0.11 valid=10s;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $remote_addr;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Proto https;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_read_timeout 3600s;
    client_max_body_size 100m;
EOF
      printf '    set $app_upstream http://%s;\n' "$upstream"
      if [[ "$role" == api ]]; then
        cat <<'EOF'
    set $api_upstream http://backend:5581;
    location /api/ { proxy_pass $api_upstream; proxy_buffering off; }
    location /health { proxy_pass $api_upstream; }
EOF
      fi
      printf '    location / { proxy_pass $app_upstream; }\n}\n'
    else
      printf '    location / { return 503; }\n}\n'
    fi
  } >"$out"
}
render_nginx() {
  local dest="$INSTALL_HOME/nginx-docker/conf.d"
  cat >"$dest/00-common.conf" <<'EOF'
map $http_upgrade $connection_upgrade { default upgrade; '' close; }
server { listen 80 default_server; server_name _; return 444; }
EOF
  if [[ "$DASHBOARD_DOMAIN" == "$API_DOMAIN" ]]; then
    nginx_server "$API_DOMAIN" "$API_DOMAIN" frontend:5582 api "$dest/api.conf"
    rm -f "$dest/dashboard.conf"
  else
    nginx_server "$API_DOMAIN" "$API_DOMAIN" backend:5581 api "$dest/api.conf"
    nginx_server "$DASHBOARD_DOMAIN" "$DASHBOARD_DOMAIN" frontend:5582 api "$dest/dashboard.conf"
  fi
  if [[ -n "$TG_DOMAIN" ]]; then
    nginx_server "$TG_DOMAIN" "$TG_DOMAIN" telegrambot:5050 bot "$dest/bot.conf"
  else rm -f "$dest/bot.conf"; fi
  if ((${#landing_domains[@]})); then
    nginx_server "${landing_domains[0]}" "${landing_domains[*]}" landing:80 landing "$dest/landing.conf"
  else rm -f "$dest/landing.conf"; fi
}
render_stacks() {
  local home="$INSTALL_HOME" key
  install -d -m 0700 "$home" "$home/host" "$home/datagate-monitor" "$home/nginx-docker"
  install -d -m 0755 "$home/datagate-monitor/resources" "$home/datagate-monitor/data-protection" "$home/datagate-monitor/redis" \
    "$home/nginx-docker/conf.d" "$home/nginx-docker/certbot/www" "$home/nginx-docker/certbot/conf"
  render_template monitor-compose.yml "$home/datagate-monitor/docker-compose.yml"
  render_template nginx-compose.yml "$home/nginx-docker/docker-compose.yml"
  {
    env_value ASPNETCORE_ENVIRONMENT "${ASPNETCORE_ENVIRONMENT:-Production}"
    env_value ASPNETCORE_URLS http://0.0.0.0:5581
    env_value DOTNET_RUNNING_IN_CONTAINER true
    env_value DB_DEFAULT_SCHEMA xgb_dashopnvpn
    env_value DB_MIGRATION_TABLE __EFMigrationsHistoryDashboardVpn
    env_value DB_CONNECTION_STRING_DATAGATE "$DB_CONNECTION_STRING_DATAGATE"
    env_value JWT_SECRET "$JWT_SECRET"
    env_value ConnectionStrings__Redis redis:6379
    env_value Auth__PublicWebBaseUrl "${Auth__PublicWebBaseUrl:-https://$DASHBOARD_DOMAIN}"
    env_value Auth__TvLoginSessionMinutes "${Auth__TvLoginSessionMinutes:-5}"
    for key in $(compgen -A variable); do
      case "$key" in EmailSender__*|GoogleAuth__*|Jwt__*|ELASTIC_*|TELEGRAM*) env_value "$key" "${!key}" ;; esac
    done
  } >"$home/datagate-monitor/backend.env"
  {
    env_value BACKEND_INTERNAL_URL http://backend:5581
    copy_env_keys VITE_CARTO_API_KEY VITE_GOOGLE_CLIENT_ID
  } >"$home/datagate-monitor/frontend.env"
  if [[ -n "$TG_DOMAIN" ]]; then
    install -d -m 0700 "$home/datagate-monitor-telegrambot"
    install -d -m 0755 "$home/datagate-monitor-telegrambot/resources" "$home/datagate-monitor-telegrambot/data-protection"
    render_template bot-compose.yml "$home/datagate-monitor-telegrambot/docker-compose.yml"
    {
      env_value ASPNETCORE_ENVIRONMENT "${ASPNETCORE_ENVIRONMENT:-Production}"
      env_value HOST_ADDRESS "$TG_DOMAIN"
      env_value TELEGRAMBOT_PORT 443
      env_value TELEGRAMBOT_LISTEN_PORT 5050
      env_value USE_CERTIFICATE false
      env_value AUTO_GENERATE_CERTIFICATE false
      env_value ForwardedHeaders__Enabled true
      env_value ForwardedHeaders__AllowAll true
      env_value TELEGRAMBOT_BOT_TOKEN "$TELEGRAMBOT_BOT_TOKEN"
      env_value DASHBOARDAPI_URL http://backend:5581/api
      copy_env_keys DASHBOARDAPI_CLIENTID DASHBOARDAPI_CLIENTSECRET TELEGRAM_REQUIRED_CHANNEL_USERNAME TELEGRAM_BOT_USERNAME
      for key in $(compgen -A variable); do
        case "$key" in ELASTIC_*|CRYPTOPAY_*|STARS_*) env_value "$key" "${!key}" ;; esac
      done
    } >"$home/datagate-monitor-telegrambot/telegrambot.env"
  fi
  if ((${#landing_domains[@]})); then
    install -d -m 0700 "$home/datagate-landing"
    render_template landing-compose.yml "$home/datagate-landing/docker-compose.yml"
  fi
  # Entire trusted config, including future OAuth/payment keys, stays on the encrypted partition.
  [[ "$env_file" == "$home/dashboard.env" ]] || install -m 0600 "$env_file" "$home/dashboard.env"
  render_nginx
  cat >"$home/host/renew-certs.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
mountpoint -q /srv/data || exit 1
cd '$home/nginx-docker'
docker compose run --rm certbot renew --webroot -w /var/www/certbot --quiet
docker compose exec -T nginx nginx -t
docker compose exec -T nginx nginx -s reload
EOF
  chmod 0700 "$home/host/renew-certs.sh"
  cat >"$home/host/datagate-dashboard-cert-renew.service" <<EOF
[Unit]
Description=Renew DataGate dashboard and Telegram certificates
After=docker.service
ConditionPathIsMountPoint=/srv/data
[Service]
Type=oneshot
ExecStart=$home/host/renew-certs.sh
EOF
  cat >"$home/host/datagate-dashboard-cert-renew.timer" <<'EOF'
[Unit]
Description=Renew DataGate dashboard certificates twice daily
ConditionPathIsMountPoint=/srv/data
[Timer]
OnCalendar=*-*-* 00,12:00:00
RandomizedDelaySec=1h
Persistent=true
[Install]
WantedBy=timers.target
EOF
  info "Rendered dashboard, Redis, nginx${TG_DOMAIN:+, Telegram bot}${LANDING_DOMAINS:+, landing} under $home"
}

compose() { local stack="$1"; shift; docker compose --project-directory "$INSTALL_HOME/$stack" "$@"; }
issue_cert() {
  local name="$1" d; shift
  local args=()
  for d in "$@"; do args+=(-d "$d"); done
  compose nginx-docker run --rm certbot certonly --webroot -w /var/www/certbot \
    --non-interactive --agree-tos --email "$CERTBOT_EMAIL" --cert-name "$name" --keep-until-expiring "${args[@]}"
}
deploy_stacks() {
  local d records src="$INSTALL_HOME/datagate-landing/source" fresh_clone=0
  local -a all_domains=("$API_DOMAIN" ${TG_DOMAIN:+"$TG_DOMAIN"} "${landing_domains[@]}")
  if [[ "$DASHBOARD_DOMAIN" != "$API_DOMAIN" ]]; then all_domains+=("$DASHBOARD_DOMAIN"); fi
  for d in "${all_domains[@]}"; do
    records="$(dig +short A "$d")"
    grep -qxF "$PUBLIC_IP" <<<"$records" || die "DNS A for $d must point to PUBLIC_IP=$PUBLIC_IP"
    # +short also prints CNAME targets (www → apex); only IPv6 addresses count.
    [[ -z "$(dig +short AAAA "$d" | grep : || true)" ]] || die "$d has AAAA records; configure IPv6 routing first or remove them before HTTP-01 issuance"
  done
  docker network inspect datagate_dashboard >/dev/null 2>&1 || docker network create datagate_dashboard >/dev/null
  compose datagate-monitor config -q
  compose datagate-monitor pull
  compose datagate-monitor up -d
  if ((${#landing_domains[@]})); then
    if [[ ! -d "$src/.git" ]]; then
      [[ ! -e "$src" ]] || die "landing source exists without .git"
      git clone --no-checkout -- "$LANDING_GIT_URL" "$src"
      fresh_clone=1
    fi
    [[ "$(git -C "$src" remote get-url origin)" == "$LANDING_GIT_URL" ]] || die "landing origin differs from LANDING_GIT_URL"
    [[ "$fresh_clone" == 1 || -z "$(git -C "$src" status --porcelain)" ]] || die "landing has local changes; commit/save them before deployment"
    git -C "$src" fetch --depth 1 origin "$LANDING_GIT_REF"
    git -C "$src" checkout --detach FETCH_HEAD
    compose datagate-landing up -d --build
  fi
  compose nginx-docker pull
  compose nginx-docker up -d nginx
  compose nginx-docker exec -T nginx nginx -t
  compose nginx-docker exec -T nginx nginx -s reload
  issue_cert "$API_DOMAIN" "$API_DOMAIN"
  if [[ "$DASHBOARD_DOMAIN" != "$API_DOMAIN" ]]; then issue_cert "$DASHBOARD_DOMAIN" "$DASHBOARD_DOMAIN"; fi
  if [[ -n "$TG_DOMAIN" ]]; then issue_cert "$TG_DOMAIN" "$TG_DOMAIN"; fi
  if ((${#landing_domains[@]})); then issue_cert "${landing_domains[0]}" "${landing_domains[@]}"; fi
  render_nginx
  compose nginx-docker exec -T nginx nginx -t
  compose nginx-docker exec -T nginx nginx -s reload
  local ready=0
  for ((attempt=0; attempt<60; attempt++)); do
    if curl -fsS --max-time 5 --resolve "$API_DOMAIN:443:127.0.0.1" "https://$API_DOMAIN/health/ready" >/dev/null; then ready=1; break; fi
    sleep 3
  done
  [[ "$ready" == 1 ]] || die "backend readiness failed; inspect datagate-monitor backend logs (DB access/migrations)"
  curl -fsS --max-time 15 --resolve "$DASHBOARD_DOMAIN:443:127.0.0.1" "https://$DASHBOARD_DOMAIN/" >/dev/null
  if [[ -n "$TG_DOMAIN" ]]; then
    # Start only after backend + public TLS work, so Telegram can reach its registered webhook.
    compose datagate-monitor-telegrambot config -q
    compose datagate-monitor-telegrambot pull
    compose datagate-monitor-telegrambot up -d
    ready=0
    for ((attempt=0; attempt<30; attempt++)); do
      if curl -fsS --max-time 5 --resolve "$TG_DOMAIN:443:127.0.0.1" "https://$TG_DOMAIN/.well-known/healthcheck" >/dev/null; then ready=1; break; fi
      sleep 3
    done
    [[ "$ready" == 1 ]] || die "Telegram bot readiness failed; inspect its credentials and logs"
    # Read token from the file, never from argv or a URL printed in logs.
    python3 - "$INSTALL_HOME/datagate-monitor-telegrambot/telegrambot.env" "$TG_DOMAIN" <<'PY'
import json, pathlib, sys, time, urllib.request
values = dict(line.split('=', 1) for line in pathlib.Path(sys.argv[1]).read_text().splitlines())
expected = f'https://{sys.argv[2]}/api/bot'
url = 'https://api.telegram.org/bot' + values['TELEGRAMBOT_BOT_TOKEN'] + '/getWebhookInfo'
for attempt in range(12):
    try:
        with urllib.request.urlopen(url, timeout=10) as response:
            data = json.load(response)
        if data.get('ok') and data.get('result', {}).get('url') == expected:
            print('Telegram webhook registered: ' + expected)
            break
    except Exception:
        pass  # urllib exceptions include the request URL/token; never print them.
    time.sleep(5)
else:
    raise SystemExit('ERROR: Telegram webhook was not registered; inspect bot startup/API credentials')
PY
  fi
  if ((${#landing_domains[@]})); then
    curl -fsS --max-time 15 --resolve "${landing_domains[0]}:443:127.0.0.1" "https://${landing_domains[0]}/" >/dev/null
  fi
  install -m 0644 "$INSTALL_HOME/host/"datagate-dashboard-cert-renew.{service,timer} /etc/systemd/system/
  systemctl daemon-reload
  systemctl add-wants datagate-dashboard-services.target datagate-dashboard-cert-renew.timer
  systemctl enable --now datagate-dashboard-cert-renew.timer
  info "DASHBOARD INSTALL OK: https://$DASHBOARD_DOMAIN/${TG_DOMAIN:+ (bot webhook: https://$TG_DOMAIN/api/bot)}"
}

main() {
  load_config
  if [[ "$mode" == render-only || "$mode" == render-draft-only ]]; then render_stacks; return; fi
  [[ "$(id -u)" == 0 ]] || die "run as root (sudo)"
  # Ubuntu 24.04 supplies Python 3.12/tomllib; the existing hardening scripts target Ubuntu too.
  # shellcheck disable=SC1091
  source /etc/os-release
  [[ "$ID" == ubuntu && "$VERSION_ID" == 24.04 ]] || die "supported host: Ubuntu 24.04 LTS"
  [[ -d /run/systemd/system ]] || die "systemd is required"
  secret_dir="$(mktemp -d /dev/shm/datagate-dashboard.XXXXXX)"
  if [[ "$mode" != deploy-only ]]; then
    echo 'DPkg::Lock::Timeout "900";' >/etc/apt/apt.conf.d/90dgsc-lock-wait
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y -qq ca-certificates curl python3 git ufw dnsutils
    ensure_encrypted_data
    prepare_docker_storage
    ensure_docker
    if [[ "$mode" != prepare-runtime-only ]]; then setup_access_and_monitoring; fi
    setup_firewall
    if [[ "$mode" != prepare-runtime-only ]]; then
      info "HOST PREPARED: SSH $ADMIN_USER@$PUBLIC_IP requires key + TOTP; console requires password + TOTP"
      info "Keep this session open and verify a second SSH login. After reboot approve the disk on your PC."
    fi
  else
    assert_encrypted_mount
    [[ -L /var/lib/docker && "$(realpath /var/lib/docker)" == /srv/data/docker ]] || die "encrypted Docker storage is not prepared"
    [[ -L /var/lib/containerd && "$(realpath /var/lib/containerd)" == /srv/data/containerd ]] || die "encrypted containerd storage is not prepared"
    [[ -f "$(getent passwd "$ADMIN_USER" | cut -d: -f6)/.google_authenticator" ]] || die "admin TOTP is not enrolled"
    local ssh_policy
    ssh_policy="$(sshd -T)"
    grep -qx 'authenticationmethods publickey,keyboard-interactive' <<<"$ssh_policy" || die "SSH key + TOTP policy is not applied"
    ensure_docker
  fi
  [[ "$mode" != prepare-only && "$mode" != prepare-runtime-only ]] || return 0
  assert_encrypted_mount
  render_stacks
  deploy_stacks
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main; fi
