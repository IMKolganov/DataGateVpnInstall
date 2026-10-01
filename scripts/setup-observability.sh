#!/usr/bin/env bash
# Node exporter + Wazuh agent + admin user (SSH key + TOTP, sudo password).
# Called by DataGate Server Control after install-vpn-host.sh. Idempotent.
#
#   sudo ./scripts/setup-observability.sh \
#     --user LINUX_USER \
#     --password-file /path \
#     --totp-secret-file /path \
#     --totp-out /path \
#     --wazuh-manager MANAGER_IP \
#     --wazuh-password-file /path \
#     --agent-name dg-host \
#     --wazuh-version 4.14.5 \
#     --node-exporter-version 1.8.2 \
#     --prometheus-ip PROMETHEUS_IP
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

ADMIN_USER=""
PASSWORD_FILE=""
TOTP_SECRET_FILE=""
TOTP_OUT=""
WAZUH_MANAGER=""
WAZUH_PASSWORD_FILE=""
AGENT_NAME=""
WAZUH_VERSION="4.14.5"
NODE_EXPORTER_VERSION="1.8.2"
PROMETHEUS_IP=""
NODE_EXPORTER_PORT="9100"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

cleanup() {
  [[ -n "${PASSWORD_FILE:-}" ]] && rm -f "$PASSWORD_FILE"
  [[ -n "${TOTP_SECRET_FILE:-}" ]] && rm -f "$TOTP_SECRET_FILE"
  [[ -n "${WAZUH_PASSWORD_FILE:-}" ]] && rm -f "$WAZUH_PASSWORD_FILE"
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) ADMIN_USER="$2"; shift 2 ;;
    --password-file) PASSWORD_FILE="$2"; shift 2 ;;
    --totp-secret-file) TOTP_SECRET_FILE="$2"; shift 2 ;;
    --totp-out) TOTP_OUT="$2"; shift 2 ;;
    --wazuh-manager) WAZUH_MANAGER="$2"; shift 2 ;;
    --wazuh-password-file) WAZUH_PASSWORD_FILE="$2"; shift 2 ;;
    --agent-name) AGENT_NAME="$2"; shift 2 ;;
    --wazuh-version) WAZUH_VERSION="$2"; shift 2 ;;
    --node-exporter-version) NODE_EXPORTER_VERSION="$2"; shift 2 ;;
    --prometheus-ip) PROMETHEUS_IP="$2"; shift 2 ;;
    --node-exporter-port) NODE_EXPORTER_PORT="$2"; shift 2 ;;
    *) die "unknown arg: $1" ;;
  esac
done

[[ -n "$ADMIN_USER" && -n "$PASSWORD_FILE" && -n "$TOTP_SECRET_FILE" && -n "$TOTP_OUT" ]] || die "user, password file, totp files are required"
[[ -n "$WAZUH_MANAGER" && -n "$AGENT_NAME" && -n "$PROMETHEUS_IP" ]] || die "wazuh manager, agent name, and prometheus IP are required"
[[ "$AGENT_NAME" =~ ^[a-z0-9][a-z0-9._-]{0,62}$ ]] || die "invalid agent name: $AGENT_NAME"
[[ "$(id -u)" -eq 0 ]] || die "run as root"
[[ -x "$SCRIPT_DIR/setup-host-ssh.sh" || -f "$SCRIPT_DIR/setup-host-ssh.sh" ]] || die "missing setup-host-ssh.sh"

install_node_exporter() {
  local arch cur=""
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac

  if [[ -x /usr/local/bin/node_exporter ]]; then
    cur="$(/usr/local/bin/node_exporter --version 2>&1 | awk 'NR==1 {print $3}' || true)"
  fi
  if [[ "$cur" != "$NODE_EXPORTER_VERSION" ]]; then
    info "Installing node_exporter ${NODE_EXPORTER_VERSION} (${arch})"
    local tmp url
    tmp="$(mktemp -d)"
    url="https://github.com/prometheus/node_exporter/releases/download/v${NODE_EXPORTER_VERSION}/node_exporter-${NODE_EXPORTER_VERSION}.linux-${arch}.tar.gz"
    curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/ne.tar.gz" "$url"
    tar -C "$tmp" -xzf "$tmp/ne.tar.gz"
    install -m 0755 "$tmp/node_exporter-${NODE_EXPORTER_VERSION}.linux-${arch}/node_exporter" /usr/local/bin/node_exporter
    rm -rf "$tmp"
  else
    info "node_exporter ${NODE_EXPORTER_VERSION} already installed"
  fi

  cat >/etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=Prometheus node exporter
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
ExecStart=/usr/local/bin/node_exporter --web.listen-address=:9100
Restart=on-failure
RestartSec=5
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  # shellcheck disable=SC2016
  sed -i "s/:9100/:${NODE_EXPORTER_PORT}/" /etc/systemd/system/node_exporter.service
  systemctl daemon-reload
  systemctl enable node_exporter
  systemctl restart node_exporter
  info "node_exporter listening on :${NODE_EXPORTER_PORT}"

  if command -v ufw >/dev/null 2>&1; then
    if ! ufw status | grep -q "${PROMETHEUS_IP}.*${NODE_EXPORTER_PORT}"; then
      ufw allow from "$PROMETHEUS_IP" to any port "$NODE_EXPORTER_PORT" proto tcp comment 'prometheus' || true
      info "UFW allows ${PROMETHEUS_IP} to :${NODE_EXPORTER_PORT}"
    fi
  fi
}

install_wazuh_agent() {
  export DEBIAN_FRONTEND=noninteractive
  local wazuh_pass="" ver
  if [[ -n "$WAZUH_PASSWORD_FILE" ]]; then
    [[ -f "$WAZUH_PASSWORD_FILE" ]] || die "wazuh registration password file not found"
    wazuh_pass="$(tr -d '\r\n' < "$WAZUH_PASSWORD_FILE")"
    [[ -n "$wazuh_pass" ]] || die "wazuh registration password file is empty"
    info "Wazuh agent will enroll with a registration password"
  else
    info "Wazuh agent will enroll without a registration password"
  fi

  if ! dpkg -s wazuh-agent >/dev/null 2>&1; then
    info "Installing wazuh-agent ${WAZUH_VERSION} → manager ${WAZUH_MANAGER} name ${AGENT_NAME}"
    apt-get update -qq
    apt-get install -y -qq curl ca-certificates gnupg
    install -d -m 0755 /usr/share/keyrings
    rm -f /usr/share/keyrings/wazuh.gpg
    curl -fsSL https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --dearmor -o /usr/share/keyrings/wazuh.gpg
    chmod 644 /usr/share/keyrings/wazuh.gpg
    echo "deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main" > /etc/apt/sources.list.d/wazuh.list
    apt-get update -qq
    ver="$(apt-cache madison wazuh-agent | awk -v want="$WAZUH_VERSION" 'index($0, want) {print $3; exit}')"
    [[ -n "$ver" ]] || die "wazuh-agent ${WAZUH_VERSION} not found in the 4.x apt repo (pin must match the manager)"
    if [[ -n "$wazuh_pass" ]]; then
      WAZUH_MANAGER="$WAZUH_MANAGER" WAZUH_AGENT_NAME="$AGENT_NAME" WAZUH_REGISTRATION_PASSWORD="$wazuh_pass" \
        apt-get install -y -qq "wazuh-agent=${ver}"
    else
      WAZUH_MANAGER="$WAZUH_MANAGER" WAZUH_AGENT_NAME="$AGENT_NAME" \
        apt-get install -y -qq "wazuh-agent=${ver}"
    fi
    apt-mark hold wazuh-agent
  else
    info "wazuh-agent already installed — pointing it at ${WAZUH_MANAGER}"
  fi

  local conf=/var/ossec/etc/ossec.conf
  [[ -f "$conf" ]] || die "missing $conf"
  awk -v ip="$WAZUH_MANAGER" '
    /<server>/ {s=1}
    s && /<address>/ {
      sub(/<address>[^<]*<\/address>/, "<address>" ip "</address>")
      s=0
    }
    {print}
  ' "$conf" > "${conf}.dgsc" && mv "${conf}.dgsc" "$conf"
  chown root:wazuh "$conf" 2>/dev/null || chown root:root "$conf"
  chmod 0640 "$conf"

  local authd=/var/ossec/etc/authd.pass
  if [[ -n "$wazuh_pass" ]]; then
    local old_umask
    old_umask="$(umask)"
    umask 077
    printf '%s\n' "$wazuh_pass" > "$authd"
    umask "$old_umask"
    chown root:wazuh "$authd" 2>/dev/null || chown root:root "$authd"
    chmod 0640 "$authd"
    info "Wrote Wazuh enrollment password to authd.pass"
  fi
  unset wazuh_pass

  systemctl daemon-reload
  systemctl enable wazuh-agent
  systemctl restart wazuh-agent
  info "wazuh-agent started (name ${AGENT_NAME}, manager ${WAZUH_MANAGER})"
}

write_sudoers() {
  local tmp f
  tmp="$(mktemp)"
  f=/etc/sudoers.d/datagate-installer
  cat > "$tmp" <<EOF
# Server Control re-install after SSH is key + TOTP. Interactive sudo still asks for the password.
${ADMIN_USER} ALL=(root) NOPASSWD: ${ROOT_DIR}/scripts/install-vpn-host.sh, ${ROOT_DIR}/scripts/setup-observability.sh, ${ROOT_DIR}/scripts/setup-host-ssh.sh
EOF
  visudo -cf "$tmp"
  install -m 0440 "$tmp" "$f"
  rm -f "$tmp"
  info "Passwordless sudo limited to the installer scripts for ${ADMIN_USER}"
}

install_node_exporter
install_wazuh_agent
write_sudoers

info "Creating ${ADMIN_USER} (SSH key + TOTP, sudo password)"
bash "$SCRIPT_DIR/setup-host-ssh.sh" \
  --user "$ADMIN_USER" \
  --password-file "$PASSWORD_FILE" \
  --totp-secret-file "$TOTP_SECRET_FILE" \
  --totp-out "$TOTP_OUT"

info "Observability and SSH 2FA finished"
