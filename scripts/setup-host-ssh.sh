#!/usr/bin/env bash
# Hardening for a DataGate VPN host: admin user + password (sudo) + SSH key + TOTP 2FA.
# Uses templates from templates/ssh/ (copied from repo ssh_configs/).
#
# Order (do this BEFORE or after VPN install — but keep a second SSH session open):
#   1) Create user, set sudo password, install authorized_keys
#   2) Enrol google-authenticator for that user
#   3) Install sshd_config + PAM (pubkey + TOTP; password login disabled)
#   If sshd -t rejects the result, the previous sshd_config / PAM / drop-in are restored and sshd is not reloaded.
#
# Usage:
#   sudo ./scripts/setup-host-ssh.sh --user YOURNAME
#   sudo ./scripts/setup-host-ssh.sh --user YOURNAME --pubkey /path/to/id_ed25519.pub
#   sudo ./scripts/setup-host-ssh.sh --user YOURNAME --pubkey-from-user ubuntu
#   sudo ./scripts/setup-host-ssh.sh --user YOURNAME --apply-sshd-only   # after .google_authenticator exists
#   sudo ./scripts/setup-host-ssh.sh --user YOURNAME --skip-password
#   sudo ./scripts/setup-host-ssh.sh --user YOURNAME --skip-totp      # no SSH 2FA: key-only sshd (still hardened)
#   sudo ./scripts/setup-host-ssh.sh --user YOURNAME --skip-sshd      # user/keys/TOTP only, sshd untouched
#   --idle-timeout SECONDS (default 600): sshd closes interactive shells / sftp / port forwards with no traffic for
#     that long (ChannelTimeout) and connections with no channels (UnusedConnectionTimeout); commands without a
#     tty (how Server Control runs installs) are not limited. Dead connections drop after ~3 min (ClientAlive).
#   sudo ./scripts/setup-host-ssh.sh --user YOURNAME --password-file /path --totp-secret-file /path --totp-out /path
#
# Keys already in /home/USER/.ssh/authorized_keys → omit --pubkey (same-file copy is a no-op).
# Covered by scripts/smoke-test-ssh-scenarios.sh.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SSH_TEMPLATES="$ROOT_DIR/templates/ssh"

ADMIN_USER=""
PUBKEY_FILE=""
PUBKEY_FROM_USER=""
APPLY_SSHD_ONLY=0
SKIP_PASSWORD=0
SKIP_TOTP=0
SKIP_SSHD=0
PASSWORD_FILE=""
TOTP_SECRET_FILE=""
TOTP_OUT=""
IDLE_TIMEOUT=600

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

usage() {
  sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

# Options that take a value: fail with a clear message instead of "unbound variable" / a silent `shift 2`.
need_value() { [[ -n "${2:-}" && "${2:0:2}" != "--" ]] || die "$1 needs a value"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) need_value "$1" "${2:-}"; ADMIN_USER="$2"; shift 2 ;;
    --pubkey) need_value "$1" "${2:-}"; PUBKEY_FILE="$2"; shift 2 ;;
    --pubkey-from-user) need_value "$1" "${2:-}"; PUBKEY_FROM_USER="$2"; shift 2 ;;
    --apply-sshd-only) APPLY_SSHD_ONLY=1; shift ;;
    --skip-password) SKIP_PASSWORD=1; shift ;;
    --skip-totp) SKIP_TOTP=1; shift ;;
    --skip-sshd) SKIP_SSHD=1; shift ;;
    --password-file) need_value "$1" "${2:-}"; PASSWORD_FILE="$2"; shift 2 ;;
    --totp-secret-file) need_value "$1" "${2:-}"; TOTP_SECRET_FILE="$2"; shift 2 ;;
    --totp-out) need_value "$1" "${2:-}"; TOTP_OUT="$2"; shift 2 ;;
    --idle-timeout) need_value "$1" "${2:-}"; IDLE_TIMEOUT="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) die "unknown arg: $1 (try --help)" ;;
  esac
done

[[ "$(id -u)" -eq 0 ]] || die "run as root: sudo $0 ..."
[[ -f "$SSH_TEMPLATES/sshd_config" ]] || die "missing $SSH_TEMPLATES/sshd_config"
[[ -f "$SSH_TEMPLATES/sshd" ]] || die "missing $SSH_TEMPLATES/sshd (PAM)"

install_packages() {
  # Re-runs (re-install, TOTP reset) must not depend on apt mirrors being reachable.
  if dpkg -s openssh-server libpam-google-authenticator >/dev/null 2>&1; then
    info "openssh-server + libpam-google-authenticator already installed"
    return 0
  fi
  info "Installing openssh-server + libpam-google-authenticator"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || die "apt-get update failed — no changes made to users, keys or sshd"
  apt-get install -y -qq openssh-server libpam-google-authenticator \
    || die "apt-get install openssh-server libpam-google-authenticator failed — no changes made"
}

ensure_user() {
  local u="$1"
  [[ -n "$u" ]] || die "--user is required"
  [[ "$u" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid username: $u"
  [[ "$u" != "root" ]] || die "do not use root — create a normal admin user"

  if id "$u" >/dev/null 2>&1; then
    info "User $u already exists"
  else
    info "Creating user $u (sudo group)"
    adduser --disabled-password --gecos "" "$u"
  fi

  usermod -aG sudo "$u"
  if getent group docker >/dev/null 2>&1; then
    usermod -aG docker "$u" || true
  fi
}

set_password() {
  local u="$1"
  if [[ -n "$PASSWORD_FILE" ]]; then
    [[ -f "$PASSWORD_FILE" ]] || die "password file not found: $PASSWORD_FILE"
    local pass
    pass="$(tr -d '\r\n' < "$PASSWORD_FILE")"
    [[ -n "$pass" ]] || die "password file is empty"
    printf '%s:%s\n' "$u" "$pass" | chpasswd
    info "Password set for $u (sudo only — not used for SSH login)"
    return 0
  fi
  if [[ "$SKIP_PASSWORD" -eq 1 ]]; then
    local st
    st="$(passwd -S "$u" 2>/dev/null | awk '{print $2}')"
    [[ "$st" == "P" ]] || die "user $u has no usable password (passwd -S → ${st:-unknown}). Run without --skip-password, or: passwd $u"
    warn "skipping password (already set)"
    return 0
  fi
  info "Set a strong password for $u (used for sudo — not for SSH login)"
  passwd "$u"
}

write_totp_out() {
  local value="$1"
  [[ -n "$TOTP_OUT" ]] || return 0
  (umask 077; printf '%s\n' "$value" > "$TOTP_OUT")
  chmod 0600 "$TOTP_OUT"
}

install_authorized_keys() {
  local u="$1"
  local home key_src
  home="$(getent passwd "$u" | cut -d: -f6)"
  [[ -d "$home" ]] || die "home missing for $u"

  if [[ -n "$PUBKEY_FILE" ]]; then
    key_src="$PUBKEY_FILE"
  elif [[ -n "$PUBKEY_FROM_USER" ]]; then
    key_src="$(getent passwd "$PUBKEY_FROM_USER" | cut -d: -f6)/.ssh/authorized_keys"
  elif [[ -f "$home/.ssh/authorized_keys" ]] && grep -qE '^(ssh-|ecdsa-)' "$home/.ssh/authorized_keys"; then
    # Prefer the target user's own keys (common: already provisioned via UpCloud / prior step)
    key_src="$home/.ssh/authorized_keys"
  elif [[ -n "${SUDO_USER:-}" && -f "$(getent passwd "$SUDO_USER" | cut -d: -f6)/.ssh/authorized_keys" ]]; then
    key_src="$(getent passwd "$SUDO_USER" | cut -d: -f6)/.ssh/authorized_keys"
  elif [[ -f /root/.ssh/authorized_keys ]]; then
    key_src=/root/.ssh/authorized_keys
  else
    die "no SSH pubkey found — pass --pubkey /path/to/id_ed25519.pub or put keys in $home/.ssh/authorized_keys"
  fi

  [[ -f "$key_src" ]] || die "pubkey source not found: $key_src"
  grep -qE '^(ssh-|ecdsa-)' "$key_src" || die "no ssh public key lines in $key_src"

  info "Installing authorized_keys for $u from $key_src"
  install -d -m 0700 -o "$u" -g "$u" "$home/.ssh"
  local dest="$home/.ssh/authorized_keys"
  # Already the target file (e.g. --pubkey ~/.ssh/authorized_keys while running as that user)
  if [[ -f "$dest" ]] && [[ "$(realpath -m "$key_src")" == "$(realpath -m "$dest")" ]]; then
    info "authorized_keys already in place — skipping copy"
    chmod 0600 "$dest"
    chown "$u:$u" "$dest"
  else
    install -m 0600 -o "$u" -g "$u" "$key_src" "$dest"
  fi
}

enrol_totp() {
  local u="$1"
  local home secret
  home="$(getent passwd "$u" | cut -d: -f6)"
  secret="$home/.google_authenticator"

  [[ "$SKIP_TOTP" -eq 1 ]] && { warn "skipping TOTP enrol"; return 0; }

  if [[ -f "$secret" ]]; then
    info "TOTP already configured: $secret"
    write_totp_out "$(head -n 1 "$secret" | tr -d '[:space:]')"
    return 0
  fi

  if [[ -n "$TOTP_SECRET_FILE" ]]; then
    [[ -f "$TOTP_SECRET_FILE" ]] || die "totp secret file not found: $TOTP_SECRET_FILE"
    local b32
    b32="$(tr -d '[:space:]' < "$TOTP_SECRET_FILE" | tr '[:lower:]' '[:upper:]')"
    [[ "$b32" =~ ^[A-Z2-7]+=*$ ]] || die "totp secret is not base32"
    umask 077
    cat > "$secret" <<EOF
${b32}
" RATE_LIMIT 3 30
" WINDOW_SIZE 3
" DISALLOW_REUSE
" TOTP_AUTH
EOF
    chmod 0400 "$secret"
    chown "$u:$u" "$secret"
    write_totp_out "$b32"
    info "TOTP enrolled for $u (secret written to the authenticator file, not printed)"
    return 0
  fi

  info "Enrolling Google Authenticator for $u (scan QR / enter secret in your app)"
  echo
  echo "  Keep this terminal open. After enrol, open a SECOND SSH session as $u"
  echo "  and confirm login works BEFORE we lock sshd to key+TOTP."
  echo
  # Interactive: shows QR + secret + scratch codes. Run as the target user.
  sudo -u "$u" -H google-authenticator -t -d -f -r 3 -R 30 -w 3 \
    || die "google-authenticator failed for $u"
  [[ -f "$secret" ]] || die "expected $secret after enrol"
  chmod 0400 "$secret"
  chown "$u:$u" "$secret"
}

SSHD_DROPIN="${DGSC_SSHD_DROPIN:-/etc/ssh/sshd_config.d/00-datagate-hardening.conf}"

# Copy each file aside before it is replaced, so a failed `sshd -t` can put the old config back.
RESTORE_LIST=()
backup_file() {
  local f="$1" bak
  if [[ -f "$f" ]]; then
    bak="${f}.bak.$(date +%Y%m%d%H%M%S)"
    cp -a "$f" "$bak"
    RESTORE_LIST+=("$f=$bak")
  else
    RESTORE_LIST+=("$f=")
  fi
}

restore_backups() {
  local pair f bak
  for pair in "${RESTORE_LIST[@]}"; do
    f="${pair%%=*}"
    bak="${pair#*=}"
    if [[ -n "$bak" ]]; then cp -a "$bak" "$f"; else rm -f "$f"; fi
  done
}

# mode: totp (key + authenticator) | key (key only — host without SSH 2FA)
sshd_dropin_body() {
  local mode="$1"
  cat <<'EOF'
# DataGate — must sort before 50-cloud-init.conf (first-value-wins)
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
UsePAM yes
X11Forwarding no
EOF
  if [[ "$mode" == "totp" ]]; then
    cat <<'EOF'
KbdInteractiveAuthentication yes
ChallengeResponseAuthentication yes
AuthenticationMethods publickey,keyboard-interactive
EOF
  else
    cat <<'EOF'
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
AuthenticationMethods publickey
EOF
  fi
  cat <<'EOF'
ClientAliveInterval 60
ClientAliveCountMax 3
EOF
  # Idle limits (OpenSSH >= 9.2). session:command is left out on purpose: installs run as commands without a tty
  # and can be silent for longer than the limit. Plain "session" is needed too: a shell opened through a client's
  # ControlMaster connection keeps that type (seen on OpenSSH 9.6), and only session:shell would never expire it.
  if [[ "${SSHD_IDLE_SUPPORTED:-1}" == "1" ]]; then
    local t="${IDLE_TIMEOUT:-600}s"
    echo "ChannelTimeout session=$t session:shell=$t session:subsystem:sftp=$t direct-tcpip=$t forwarded-tcpip=$t"
    echo "UnusedConnectionTimeout $t"
  fi
}

# OpenSSH < 9.2 does not know ChannelTimeout / UnusedConnectionTimeout; writing them would fail sshd -t.
detect_sshd_idle_support() {
  SSHD_IDLE_SUPPORTED=0
  if command -v sshd >/dev/null 2>&1 \
    && sshd -t -o "ChannelTimeout=session:shell=600s" -o "UnusedConnectionTimeout=600s" >/dev/null 2>&1; then
    SSHD_IDLE_SUPPORTED=1
  else
    warn "this sshd has no ChannelTimeout/UnusedConnectionTimeout (OpenSSH < 9.2) — only TMOUT limits idle shells"
  fi
}

reload_sshd() {
  # Single-unit queries: piping the full unit list into `grep -q` can SIGPIPE systemctl and, under
  # pipefail, make an existing unit look missing.
  if systemctl is-active --quiet ssh.socket 2>/dev/null; then
    systemctl reload ssh.socket 2>/dev/null || systemctl restart ssh.socket
  fi
  if systemctl cat ssh.service >/dev/null 2>&1; then
    systemctl reload ssh 2>/dev/null || systemctl restart ssh
  elif systemctl cat sshd.service >/dev/null 2>&1; then
    systemctl reload sshd 2>/dev/null || systemctl restart sshd
  else
    service ssh reload 2>/dev/null || service ssh restart || warn "could not reload sshd — restart it manually"
  fi
}

apply_sshd() {
  local u="${1:-}" mode="${2:-totp}"
  if [[ "$mode" == "totp" && -n "$u" ]]; then
    local secret
    secret="$(getent passwd "$u" | cut -d: -f6)/.google_authenticator"
    [[ -f "$secret" ]] || die "missing $secret — enrol TOTP before applying sshd (or use --skip-totp for key-only SSH)"
  fi

  info "Installing sshd_config + PAM from templates/ssh (repo ssh_configs)"
  RESTORE_LIST=()
  backup_file /etc/ssh/sshd_config
  backup_file /etc/pam.d/sshd
  backup_file "$SSHD_DROPIN"

  install -m 0644 "$SSH_TEMPLATES/sshd_config" /etc/ssh/sshd_config
  install -m 0644 "$SSH_TEMPLATES/sshd" /etc/pam.d/sshd

  # OpenSSH: first value wins; Include sshd_config.d runs before main-file keywords.
  # Write 00-datagate so we beat cloud-init (50-cloud-init.conf) on Ubuntu images.
  mkdir -p "$(dirname "$SSHD_DROPIN")"
  detect_sshd_idle_support
  sshd_dropin_body "$mode" > "$SSHD_DROPIN"
  chmod 0644 "$SSHD_DROPIN"
  info "Wrote $SSHD_DROPIN (overrides cloud-init; mode: $mode)"

  # Fresh cloud images sometimes miss PrivSep dir until ssh.service starts once.
  if [[ ! -d /run/sshd ]]; then
    info "Creating /run/sshd (privilege separation directory)"
    mkdir -p /run/sshd
    chmod 0755 /run/sshd
  fi

  if command -v sshd >/dev/null 2>&1 && ! sshd -t; then
    restore_backups
    die "sshd -t rejected the new config — previous sshd_config / PAM / drop-in restored, sshd not reloaded"
  fi

  reload_sshd
  info "sshd reloaded"
  echo
  echo "======== SSH policy ========"
  if [[ "$mode" == "totp" ]]; then
    echo "  Login: SSH key + Google Authenticator (TOTP) — only ${u:-the enrolled user}; accounts without TOTP cannot log in"
  else
    echo "  Login: SSH key only (no 2FA). Enrol TOTP later and re-run with --apply-sshd-only to require it."
  fi
  echo "  Root login: disabled"
  echo "  Password SSH: disabled (password is for sudo only)"
  echo
  echo "TEST NOW from another terminal:"
  echo "  ssh ${u:-USER}@HOST"
  [[ "$mode" == "totp" ]] && echo "  (enter TOTP when prompted; do not close this session until it works)"
  echo
}

print_reminder() {
  local u="$1"
  cat <<EOF

======== DONE (SSH hardening) ========
User:     $u
Home:     $(getent passwd "$u" | cut -d: -f6)
SSH:      publickey + keyboard-interactive (TOTP via pam_google_authenticator)
Sudo:     password you set with passwd

Next:
  1) Open a NEW SSH session as $u and confirm key + TOTP work
  2) Only then close the old session
  3) Continue VPN install (as $u):
       cd ~/vpns   # or copy install/vpns under /home/$u
       sudo ./scripts/install-vpn-host.sh --wizard
     Set INSTALL_HOME=/home/$u in site.env

EOF
}

# Check every input file before the first change (user, keys, sshd), so a bad argument never leaves a
# half-configured host.
preflight() {
  [[ "$IDLE_TIMEOUT" =~ ^[0-9]+$ && "$IDLE_TIMEOUT" -ge 60 ]] || die "--idle-timeout must be seconds >= 60"
  if [[ -n "$ADMIN_USER" ]]; then
    [[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid username: $ADMIN_USER"
    [[ "$ADMIN_USER" != "root" ]] || die "do not use root — create a normal admin user"
  fi
  if [[ -n "$PASSWORD_FILE" ]]; then
    [[ -f "$PASSWORD_FILE" ]] || die "password file not found: $PASSWORD_FILE"
    [[ -n "$(tr -d '\r\n' < "$PASSWORD_FILE")" ]] || die "password file is empty"
  fi
  if [[ -n "$TOTP_SECRET_FILE" && "$SKIP_TOTP" -eq 0 ]]; then
    [[ -f "$TOTP_SECRET_FILE" ]] || die "totp secret file not found: $TOTP_SECRET_FILE"
    tr -d '[:space:]' < "$TOTP_SECRET_FILE" | tr '[:lower:]' '[:upper:]' | grep -qE '^[A-Z2-7]+=*$' \
      || die "totp secret is not base32"
  fi
  if [[ -n "$PUBKEY_FILE" ]]; then
    [[ -f "$PUBKEY_FILE" ]] || die "pubkey file not found: $PUBKEY_FILE"
  fi
}

main() {
  preflight
  install_packages

  # --skip-totp = host without SSH 2FA: sshd is still hardened, just key-only.
  local mode=totp
  [[ "$SKIP_TOTP" -eq 1 ]] && mode=key

  if [[ "$APPLY_SSHD_ONLY" -eq 1 ]]; then
    [[ -n "$ADMIN_USER" ]] || die "--apply-sshd-only needs --user (to verify .google_authenticator)"
    apply_sshd "$ADMIN_USER" "$mode"
    exit 0
  fi

  [[ -n "$ADMIN_USER" ]] || die "pass --user YOURNAME"

  ensure_user "$ADMIN_USER"
  set_password "$ADMIN_USER"
  install_authorized_keys "$ADMIN_USER"
  enrol_totp "$ADMIN_USER"

  if [[ "$SKIP_SSHD" -eq 1 ]]; then
    warn "sshd/PAM not applied yet — when ready, run:"
    echo "  sudo $0 --user $ADMIN_USER --apply-sshd-only$([[ "$mode" == key ]] && echo ' --skip-totp')"
  else
    [[ "$mode" == key ]] && warn "--skip-totp: SSH will be key-only (no 2FA)"
    apply_sshd "$ADMIN_USER" "$mode"
  fi

  print_reminder "$ADMIN_USER"
}

main
