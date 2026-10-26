#!/usr/bin/env bash
# Console hardening for a DataGate VPN host (UpCloud web console / serial console). Idempotent.
#   1) Console login (PAM "login") asks for the password AND the same TOTP as SSH (~/.google_authenticator).
#      Accounts without a TOTP file (root included) cannot log in on the console.
#   2) GRUB superuser password: normal boot stays unattended, but editing boot entries (init=/bin/bash)
#      and recovery mode need the password. Recovery entries are removed from the menu.
#   3) Idle interactive shells (SSH and console) are closed after --idle-timeout seconds (TMOUT, read-only).
#
# Run AFTER setup-host-ssh.sh has enrolled TOTP for --user.
#
#   sudo ./scripts/setup-host-console.sh --user dgadmin --grub-password-file /path [--idle-timeout 600]
#   sudo ./scripts/setup-host-console.sh --user dgadmin --skip-grub
#
# Paths and tools can be overridden with env vars (DGSC_PAM_LOGIN, DGSC_GRUB_D, DGSC_GRUB_DEFAULT_D,
# DGSC_GRUB_CFG, DGSC_PROFILE_D, DGSC_STATE_DIR, DGSC_UPDATE_GRUB, DGSC_GRUB_MKPASSWD, DGSC_SKIP_ROOT_CHECK) — used by
# scripts/smoke-test-console-hardening.sh. Do not set them on a real host.
set -euo pipefail

ADMIN_USER=""
GRUB_PASSWORD_FILE=""
SKIP_GRUB=0
IDLE_TIMEOUT=600

PAM_LOGIN="${DGSC_PAM_LOGIN:-/etc/pam.d/login}"
GRUB_D="${DGSC_GRUB_D:-/etc/grub.d}"
GRUB_DEFAULT_D="${DGSC_GRUB_DEFAULT_D:-/etc/default/grub.d}"
GRUB_CFG="${DGSC_GRUB_CFG:-/boot/grub/grub.cfg}"
PROFILE_D="${DGSC_PROFILE_D:-/etc/profile.d}"
# Backups live outside /etc/grub.d: grub-mkconfig runs every executable NN_* file there, so a copy of
# 10_linux next to it would add a second, password-protected set of boot entries.
STATE_DIR="${DGSC_STATE_DIR:-/var/lib/datagate-console}"
UPDATE_GRUB="${DGSC_UPDATE_GRUB:-update-grub}"
GRUB_MKPASSWD="${DGSC_GRUB_MKPASSWD:-grub-mkpasswd-pbkdf2}"

GRUB_SUPERUSER="dgsc-grub"
PAM_MARKER="# datagate: console TOTP"
GRUB_PASSWORD_SCRIPT="$GRUB_D/01_datagate_password"
GRUB_LINUX_SCRIPT="$GRUB_D/10_linux"
GRUB_LINUX_ORIG="$STATE_DIR/10_linux.orig"
LEGACY_GRUB_LINUX_ORIG="$GRUB_D/10_linux.dgsc-orig"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

cleanup() {
  [[ -n "${GRUB_PASSWORD_FILE:-}" ]] && rm -f "$GRUB_PASSWORD_FILE"
  # An EXIT trap's status becomes the script's exit code — a skipped `&&` above must not turn success into 1.
  return 0
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) ADMIN_USER="$2"; shift 2 ;;
    --grub-password-file) GRUB_PASSWORD_FILE="$2"; shift 2 ;;
    --skip-grub) SKIP_GRUB=1; shift ;;
    --idle-timeout) IDLE_TIMEOUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown arg: $1 (try --help)" ;;
  esac
done

[[ "${DGSC_SKIP_ROOT_CHECK:-0}" == "1" || "$(id -u)" -eq 0 ]] || die "run as root: sudo $0 ..."
[[ -n "$ADMIN_USER" ]] || die "--user is required"
[[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid username: $ADMIN_USER"
[[ "$IDLE_TIMEOUT" =~ ^[0-9]+$ && "$IDLE_TIMEOUT" -ge 60 ]] || die "--idle-timeout must be seconds >= 60"
[[ "$SKIP_GRUB" -eq 1 || -n "$GRUB_PASSWORD_FILE" ]] || die "pass --grub-password-file or --skip-grub"

user_home() {
  if [[ -n "${DGSC_USER_HOME:-}" ]]; then
    printf '%s\n' "$DGSC_USER_HOME"
  else
    getent passwd "$1" | cut -d: -f6
  fi
}

# --- 1) Console TOTP -------------------------------------------------------------------------------

apply_console_totp() {
  local home
  home="$(user_home "$ADMIN_USER")"
  [[ -f "$home/.google_authenticator" ]] \
    || die "missing $home/.google_authenticator — enrol TOTP (setup-host-ssh.sh) before locking the console"
  [[ -f "$PAM_LOGIN" ]] || die "missing $PAM_LOGIN"

  if grep -qF "$PAM_MARKER" "$PAM_LOGIN"; then
    info "Console TOTP already required in $PAM_LOGIN"
    return 0
  fi
  grep -qE '^@include[[:space:]]+common-auth' "$PAM_LOGIN" \
    || die "$PAM_LOGIN has no '@include common-auth' line — refusing to guess where TOTP goes"

  cp -a "$PAM_LOGIN" "${PAM_LOGIN}.bak.$(date +%Y%m%d%H%M%S)"
  # Password first (common-auth), then TOTP. No nullok: an account without a TOTP file cannot log in here.
  local tmp
  tmp="$(mktemp)"
  awk -v marker="$PAM_MARKER" '
    { print }
    !done && /^@include[[:space:]]+common-auth/ {
      print marker
      print "auth required pam_google_authenticator.so"
      done = 1
    }
  ' "$PAM_LOGIN" > "$tmp"
  install -m 0644 "$tmp" "$PAM_LOGIN"
  rm -f "$tmp"
  info "Console login now asks for password + TOTP ($PAM_LOGIN)"
}

# --- 2) GRUB password ------------------------------------------------------------------------------

grub_hash() {
  local pass="$1" out
  out="$(printf '%s\n%s\n' "$pass" "$pass" | "$GRUB_MKPASSWD" 2>/dev/null)" || return 1
  printf '%s\n' "$out" | grep -oE 'grub\.pbkdf2\.[^[:space:]]+' | tail -n 1
}

# Every bootable Linux entry must stay --unrestricted, otherwise the host would stop at a password
# prompt on every reboot and the VPN would not come back.
grub_cfg_boots_unattended() {
  [[ -f "$GRUB_CFG" ]] || return 1
  local linux_entries restricted
  linux_entries="$(grep -cE "^[[:space:]]*menuentry .*--class gnu-linux" "$GRUB_CFG" || true)"
  [[ "$linux_entries" -gt 0 ]] || return 1
  restricted="$(grep -E "^[[:space:]]*menuentry .*--class gnu-linux" "$GRUB_CFG" | grep -vc -- '--unrestricted' || true)"
  [[ "$restricted" -eq 0 ]]
}

rollback_grub() {
  warn "Rolling back the GRUB password so the host keeps booting unattended"
  rm -f "$GRUB_PASSWORD_SCRIPT"
  if [[ -f "$GRUB_LINUX_ORIG" ]]; then
    cp -p "$GRUB_LINUX_ORIG" "$GRUB_LINUX_SCRIPT"
    chmod 0755 "$GRUB_LINUX_SCRIPT"
  fi
  "$UPDATE_GRUB" >/dev/null 2>&1 || warn "$UPDATE_GRUB failed during rollback — check $GRUB_CFG before rebooting"
}

apply_grub_password() {
  if [[ "$SKIP_GRUB" -eq 1 ]]; then
    warn "Skipping GRUB password (--skip-grub)"
    return 0
  fi
  if ! command -v "$UPDATE_GRUB" >/dev/null 2>&1 || [[ ! -f "$GRUB_LINUX_SCRIPT" ]]; then
    warn "GRUB tools not found ($UPDATE_GRUB / $GRUB_LINUX_SCRIPT) — GRUB password not set"
    return 0
  fi
  [[ -f "$GRUB_PASSWORD_FILE" ]] || die "grub password file not found: $GRUB_PASSWORD_FILE"
  local pass hash
  pass="$(tr -d '\r\n' < "$GRUB_PASSWORD_FILE")"
  [[ ${#pass} -ge 12 ]] || die "grub password must be at least 12 characters"
  hash="$(grub_hash "$pass")" || die "$GRUB_MKPASSWD failed"
  unset pass
  [[ "$hash" == grub.pbkdf2.* ]] || die "$GRUB_MKPASSWD returned no pbkdf2 hash"

  # Boot entries from 10_linux stay unrestricted (unattended reboot); everything else needs the password.
  install -d -m 0700 "$STATE_DIR"
  if [[ -f "$LEGACY_GRUB_LINUX_ORIG" ]]; then
    [[ -f "$GRUB_LINUX_ORIG" ]] || cp -p "$LEGACY_GRUB_LINUX_ORIG" "$GRUB_LINUX_ORIG"
    rm -f "$LEGACY_GRUB_LINUX_ORIG"
  fi
  [[ -f "$GRUB_LINUX_ORIG" ]] || cp -p "$GRUB_LINUX_SCRIPT" "$GRUB_LINUX_ORIG"
  chmod 0600 "$GRUB_LINUX_ORIG"
  if ! grep -qE '^CLASS="[^"]*--unrestricted' "$GRUB_LINUX_SCRIPT"; then
    grep -qE '^CLASS="' "$GRUB_LINUX_SCRIPT" || die "$GRUB_LINUX_SCRIPT has no CLASS= line — cannot keep boot unrestricted"
    sed -i -E 's/^CLASS="([^"]*)"/CLASS="\1 --unrestricted"/' "$GRUB_LINUX_SCRIPT"
  fi

  local old_umask
  old_umask="$(umask)"
  umask 077
  cat > "$GRUB_PASSWORD_SCRIPT" <<EOF
#!/bin/sh
# DataGate: GRUB superuser. Booting is unrestricted; editing entries / recovery needs the password.
cat <<'GRUBEOF'
set superusers="${GRUB_SUPERUSER}"
password_pbkdf2 ${GRUB_SUPERUSER} ${hash}
GRUBEOF
EOF
  umask "$old_umask"
  chmod 0700 "$GRUB_PASSWORD_SCRIPT"

  mkdir -p "$GRUB_DEFAULT_D"
  cat > "$GRUB_DEFAULT_D/99-datagate-recovery.cfg" <<'EOF'
# DataGate: no recovery (single-user root shell) entries in the boot menu.
GRUB_DISABLE_RECOVERY="true"
EOF

  if ! "$UPDATE_GRUB" >/dev/null 2>&1; then
    rollback_grub
    die "$UPDATE_GRUB failed — GRUB password rolled back"
  fi
  if ! grub_cfg_boots_unattended; then
    rollback_grub
    die "generated $GRUB_CFG would ask for a password at boot — GRUB password rolled back"
  fi
  if ! grep -qF "set superusers=\"${GRUB_SUPERUSER}\"" "$GRUB_CFG"; then
    rollback_grub
    die "generated $GRUB_CFG has no superuser — GRUB password rolled back"
  fi
  info "GRUB password set (user ${GRUB_SUPERUSER}); normal boot stays unattended, recovery entries removed"
}

# --- 3) Idle timeout -------------------------------------------------------------------------------

apply_idle_timeout() {
  mkdir -p "$PROFILE_D"
  cat > "$PROFILE_D/99-datagate-idle-timeout.sh" <<EOF
# DataGate: close idle interactive shells (SSH and console) after ${IDLE_TIMEOUT}s at the prompt.
# Running commands are not interrupted; non-interactive SSH commands are not affected.
if [ "\${TMOUT:-}" != "${IDLE_TIMEOUT}" ]; then
  TMOUT=${IDLE_TIMEOUT} 2>/dev/null
fi
readonly TMOUT 2>/dev/null
export TMOUT
EOF
  chmod 0644 "$PROFILE_D/99-datagate-idle-timeout.sh"
  info "Idle shells close after ${IDLE_TIMEOUT}s ($PROFILE_D/99-datagate-idle-timeout.sh)"
}

apply_console_totp
apply_grub_password
apply_idle_timeout

info "Console hardening finished for ${ADMIN_USER}"
