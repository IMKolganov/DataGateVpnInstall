#!/usr/bin/env bash
# Console hardening for a DataGate VPN host (UpCloud web console / serial console). Idempotent.
#   1) Console login (PAM "login") asks for the password AND the same TOTP as SSH (~/.google_authenticator).
#      Accounts without a TOTP file (root included) cannot log in on the console.
#      --no-totp: host without 2FA — console asks for the password only (removes the TOTP line if present).
#   2) GRUB superuser password: normal boot stays unattended, but editing boot entries (init=/bin/bash)
#      and recovery mode need the password. Recovery entries are removed from the menu. An apt hook puts
#      --unrestricted back if a grub package update replaces /etc/grub.d/10_linux.
#   3) Idle interactive shells (SSH and console) are closed after --idle-timeout seconds (TMOUT, read-only).
#
# Every input is checked before anything is changed. Run AFTER setup-host-ssh.sh has enrolled TOTP.
#
#   sudo ./scripts/setup-host-console.sh --user dgadmin --grub-password-file /path [--idle-timeout 600]
#   sudo ./scripts/setup-host-console.sh --user dgadmin --skip-grub
#   sudo ./scripts/setup-host-console.sh --user dgadmin --no-totp --skip-grub
#
# Paths and tools can be overridden with env vars (DGSC_PAM_LOGIN, DGSC_GRUB_D, DGSC_GRUB_DEFAULT_D,
# DGSC_GRUB_CFG, DGSC_PROFILE_D, DGSC_STATE_DIR, DGSC_GUARD_BIN, DGSC_APT_CONF_D, DGSC_UPDATE_GRUB,
# DGSC_GRUB_MKPASSWD, DGSC_USER_HOME, DGSC_SKIP_ROOT_CHECK) — used by scripts/smoke-test-console-hardening.sh.
# Do not set them on a real host.
set -euo pipefail

ADMIN_USER=""
GRUB_PASSWORD_FILE=""
SKIP_GRUB=0
NO_TOTP=0
IDLE_TIMEOUT=600

PAM_LOGIN="${DGSC_PAM_LOGIN:-/etc/pam.d/login}"
GRUB_D="${DGSC_GRUB_D:-/etc/grub.d}"
GRUB_DEFAULT_D="${DGSC_GRUB_DEFAULT_D:-/etc/default/grub.d}"
GRUB_CFG="${DGSC_GRUB_CFG:-/boot/grub/grub.cfg}"
PROFILE_D="${DGSC_PROFILE_D:-/etc/profile.d}"
# Backups live outside /etc/grub.d: grub-mkconfig runs every executable NN_* file there, so a copy of
# 10_linux next to it would add a second, password-protected set of boot entries.
STATE_DIR="${DGSC_STATE_DIR:-/var/lib/datagate-console}"
GUARD_BIN="${DGSC_GUARD_BIN:-/usr/local/sbin/datagate-grub-guard}"
APT_CONF_D="${DGSC_APT_CONF_D:-/etc/apt/apt.conf.d}"
UPDATE_GRUB="${DGSC_UPDATE_GRUB:-update-grub}"
GRUB_MKPASSWD="${DGSC_GRUB_MKPASSWD:-grub-mkpasswd-pbkdf2}"

GRUB_SUPERUSER="dgsc-grub"
PAM_MARKER="# datagate: console TOTP"
PAM_TOTP_LINE="auth required pam_google_authenticator.so"
GRUB_PASSWORD_SCRIPT="$GRUB_D/01_datagate_password"
GRUB_LINUX_SCRIPT="$GRUB_D/10_linux"
GRUB_LINUX_ORIG="$STATE_DIR/10_linux.orig"
LEGACY_GRUB_LINUX_ORIG="$GRUB_D/10_linux.dgsc-orig"
IDLE_FILE="$PROFILE_D/99-datagate-idle-timeout.sh"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
warn() { echo "WARN: $*" >&2; }

cleanup() {
  [[ -n "${GRUB_PASSWORD_FILE:-}" ]] && rm -f "$GRUB_PASSWORD_FILE"
  # An EXIT trap's status becomes the script's exit code — a skipped `&&` above must not turn success into 1.
  return 0
}
trap cleanup EXIT

# Options that take a value: fail with a clear message instead of "unbound variable" / a silent `shift 2`.
need_value() { [[ -n "${2:-}" && "${2:0:2}" != "--" ]] || die "$1 needs a value"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) need_value "$1" "${2:-}"; ADMIN_USER="$2"; shift 2 ;;
    --grub-password-file) need_value "$1" "${2:-}"; GRUB_PASSWORD_FILE="$2"; shift 2 ;;
    --skip-grub) SKIP_GRUB=1; shift ;;
    --no-totp) NO_TOTP=1; shift ;;
    --idle-timeout) need_value "$1" "${2:-}"; IDLE_TIMEOUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown arg: $1 (try --help)" ;;
  esac
done

# --- Preflight: validate everything before the first change -------------------------------------------

[[ "${DGSC_SKIP_ROOT_CHECK:-0}" == "1" || "$(id -u)" -eq 0 ]] || die "run as root: sudo $0 ..."
[[ -n "$ADMIN_USER" ]] || die "--user is required"
[[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "invalid username: $ADMIN_USER"
[[ "$ADMIN_USER" != "root" ]] || die "do not use root — pass the admin user created by setup-host-ssh.sh"
[[ "$IDLE_TIMEOUT" =~ ^[0-9]+$ && "$IDLE_TIMEOUT" -ge 60 ]] || die "--idle-timeout must be seconds >= 60"
if [[ "$SKIP_GRUB" -eq 1 && -n "$GRUB_PASSWORD_FILE" ]]; then
  die "--skip-grub and --grub-password-file are mutually exclusive"
fi
[[ "$SKIP_GRUB" -eq 1 || -n "$GRUB_PASSWORD_FILE" ]] || die "pass --grub-password-file or --skip-grub"

if [[ -n "${DGSC_USER_HOME:-}" ]]; then
  USER_HOME="$DGSC_USER_HOME"
else
  USER_HOME="$(getent passwd "$ADMIN_USER" | cut -d: -f6 || true)"
  [[ -n "$USER_HOME" ]] || die "user $ADMIN_USER does not exist — run setup-host-ssh.sh first"
fi

[[ -f "$PAM_LOGIN" ]] || die "missing $PAM_LOGIN"
if [[ "$NO_TOTP" -eq 0 ]]; then
  [[ -f "$USER_HOME/.google_authenticator" ]] \
    || die "no TOTP enrolled for $ADMIN_USER ($USER_HOME/.google_authenticator missing) — run setup-host-ssh.sh first, or pass --no-totp for a host without 2FA"
  grep -qF "$PAM_MARKER" "$PAM_LOGIN" || grep -qE '^@include[[:space:]]+common-auth' "$PAM_LOGIN" \
    || die "$PAM_LOGIN has no '@include common-auth' line — refusing to guess where TOTP goes"
fi

GRUB_PASS=""
GRUB_AVAILABLE=1
if [[ "$SKIP_GRUB" -eq 0 ]]; then
  [[ -f "$GRUB_PASSWORD_FILE" ]] || die "grub password file not found: $GRUB_PASSWORD_FILE"
  GRUB_PASS="$(tr -d '\r\n' < "$GRUB_PASSWORD_FILE")"
  [[ ${#GRUB_PASS} -ge 12 ]] || die "grub password must be at least 12 characters"
  if ! command -v "$UPDATE_GRUB" >/dev/null 2>&1 || [[ ! -f "$GRUB_LINUX_SCRIPT" ]]; then
    GRUB_AVAILABLE=0
  elif ! grep -qE '^CLASS="' "$GRUB_LINUX_SCRIPT"; then
    die "$GRUB_LINUX_SCRIPT has no CLASS= line — cannot keep boot unattended with a GRUB password"
  fi
fi

# --- 1) Console TOTP -------------------------------------------------------------------------------

backup_pam_login() { cp -a "$PAM_LOGIN" "${PAM_LOGIN}.bak.$(date +%Y%m%d%H%M%S)"; }

apply_console_totp() {
  if grep -qF "$PAM_MARKER" "$PAM_LOGIN"; then
    info "Console TOTP already required in $PAM_LOGIN"
    return 0
  fi
  backup_pam_login
  # Password first (common-auth), then TOTP. No nullok: an account without a TOTP file cannot log in here.
  local tmp
  tmp="$(mktemp)"
  awk -v marker="$PAM_MARKER" -v line="$PAM_TOTP_LINE" '
    { print }
    !done && /^@include[[:space:]]+common-auth/ { print marker; print line; done = 1 }
  ' "$PAM_LOGIN" > "$tmp"
  install -m 0644 "$tmp" "$PAM_LOGIN"
  rm -f "$tmp"
  info "Console login now asks for password + TOTP ($PAM_LOGIN)"
}

# Host without 2FA: drop our TOTP line, otherwise nobody could log in on the console once the TOTP file is gone.
remove_console_totp() {
  if ! grep -qF "$PAM_MARKER" "$PAM_LOGIN"; then
    info "Console login: password only (no TOTP line in $PAM_LOGIN)"
    return 0
  fi
  backup_pam_login
  local tmp
  tmp="$(mktemp)"
  awk -v marker="$PAM_MARKER" -v line="$PAM_TOTP_LINE" '
    $0 == marker { skip = 1; next }
    skip && $0 == line { skip = 0; next }
    { skip = 0; print }
  ' "$PAM_LOGIN" > "$tmp"
  install -m 0644 "$tmp" "$PAM_LOGIN"
  rm -f "$tmp"
  warn "Console TOTP removed (--no-totp): console login asks for the password only"
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

# dpkg Post-Invoke hook: a grub package update can replace a modified 10_linux (e.g. "install the package
# maintainer's version" at an interactive prompt). Without --unrestricted the next reboot would stop at the
# GRUB password prompt, so put it back — or, if that fails, drop the GRUB password: booting wins.
install_grub_guard() {
  mkdir -p "$(dirname "$GUARD_BIN")" "$APT_CONF_D"
  cat > "$GUARD_BIN" <<EOF
#!/bin/sh
# DataGate: keep Linux boot entries --unrestricted after grub package updates. Never fails apt.
G="$GRUB_D"
[ -f "\$G/01_datagate_password" ] && [ -f "\$G/10_linux" ] || exit 0
grep -qE '^CLASS="[^"]*--unrestricted' "\$G/10_linux" && exit 0
say() { logger -t datagate-grub-guard "\$*" 2>/dev/null || echo "datagate-grub-guard: \$*" >&2; }
if grep -qE '^CLASS="' "\$G/10_linux"; then
  mkdir -p "$STATE_DIR" && cp -p "\$G/10_linux" "$GRUB_LINUX_ORIG"
  sed -i -E 's/^CLASS="([^"]*)"/CLASS="\\1 --unrestricted"/' "\$G/10_linux"
  if "$UPDATE_GRUB" >/dev/null 2>&1 \\
    && ! grep -E '^[[:space:]]*menuentry .*--class gnu-linux' "$GRUB_CFG" | grep -qv -- '--unrestricted'; then
    say "10_linux was replaced by a package update; --unrestricted restored"
    exit 0
  fi
fi
rm -f "\$G/01_datagate_password"
"$UPDATE_GRUB" >/dev/null 2>&1 || true
say "could not keep boot entries unrestricted — GRUB password removed so the host still boots; re-run setup-host-console.sh"
exit 0
EOF
  chmod 0755 "$GUARD_BIN"
  cat > "$APT_CONF_D/99-datagate-grub-guard" <<EOF
// DataGate: keep GRUB boot entries unrestricted after grub package updates.
DPkg::Post-Invoke { "if [ -x $GUARD_BIN ]; then $GUARD_BIN || true; fi"; };
EOF
  chmod 0644 "$APT_CONF_D/99-datagate-grub-guard"
}

apply_grub_password() {
  if [[ "$SKIP_GRUB" -eq 1 ]]; then
    info "Skipping GRUB password (--skip-grub)"
    return 0
  fi
  if [[ "$GRUB_AVAILABLE" -eq 0 ]]; then
    warn "GRUB password NOT set: $UPDATE_GRUB / $GRUB_LINUX_SCRIPT not found on this host (console TOTP and idle timeout still applied)"
    return 0
  fi
  local hash
  hash="$(grub_hash "$GRUB_PASS")" || die "$GRUB_MKPASSWD failed"
  GRUB_PASS=""
  [[ "$hash" == grub.pbkdf2.* ]] || die "$GRUB_MKPASSWD returned no pbkdf2 hash"

  # Boot entries from 10_linux stay unrestricted (unattended reboot); everything else needs the password.
  install -d -m 0700 "$STATE_DIR"
  if [[ -f "$LEGACY_GRUB_LINUX_ORIG" ]]; then
    [[ -f "$GRUB_LINUX_ORIG" ]] || cp -p "$LEGACY_GRUB_LINUX_ORIG" "$GRUB_LINUX_ORIG"
    rm -f "$LEGACY_GRUB_LINUX_ORIG"
  fi
  # A 10_linux without --unrestricted is the pristine package file (first run, or a package update replaced
  # ours): that is the copy to restore on rollback, not an older backup.
  if ! grep -qE '^CLASS="[^"]*--unrestricted' "$GRUB_LINUX_SCRIPT"; then
    cp -p "$GRUB_LINUX_SCRIPT" "$GRUB_LINUX_ORIG"
    sed -i -E 's/^CLASS="([^"]*)"/CLASS="\1 --unrestricted"/' "$GRUB_LINUX_SCRIPT"
  fi
  [[ -f "$GRUB_LINUX_ORIG" ]] && chmod 0600 "$GRUB_LINUX_ORIG"

  (
    umask 077
    cat > "$GRUB_PASSWORD_SCRIPT" <<EOF
#!/bin/sh
# DataGate: GRUB superuser. Booting is unrestricted; editing entries / recovery needs the password.
cat <<'GRUBEOF'
set superusers="${GRUB_SUPERUSER}"
password_pbkdf2 ${GRUB_SUPERUSER} ${hash}
GRUBEOF
EOF
  )
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
  install_grub_guard
  info "GRUB password set (user ${GRUB_SUPERUSER}); normal boot stays unattended, recovery entries removed"
}

# --- 3) Idle timeout -------------------------------------------------------------------------------

apply_idle_timeout() {
  mkdir -p "$PROFILE_D"
  cat > "$IDLE_FILE" <<EOF
# DataGate: close idle interactive shells (SSH and console) after ${IDLE_TIMEOUT}s at the prompt.
# Interactive shells only and not exported: scripts started from such a shell must not inherit TMOUT
# (bash uses it as the default timeout of the read builtin). Running commands are not interrupted.
case \$- in
  *i*)
    if [ "\${TMOUT:-}" != "${IDLE_TIMEOUT}" ]; then
      TMOUT=${IDLE_TIMEOUT} 2>/dev/null
    fi
    readonly TMOUT 2>/dev/null
    ;;
esac
EOF
  chmod 0644 "$IDLE_FILE"
  info "Idle shells close after ${IDLE_TIMEOUT}s ($IDLE_FILE)"
}

if [[ "$NO_TOTP" -eq 1 ]]; then
  remove_console_totp
else
  apply_console_totp
fi
apply_grub_password
apply_idle_timeout

info "Console hardening finished for ${ADMIN_USER}"
