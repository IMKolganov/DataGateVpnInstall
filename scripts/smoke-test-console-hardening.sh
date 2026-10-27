#!/usr/bin/env bash
# Non-root scenario tests for setup-host-console.sh (PAM console TOTP, GRUB password, idle timeout).
# Runs the real script against a sandbox: paths and update-grub are overridden via DGSC_* env vars.
# Uses the real grub-mkpasswd-pbkdf2 when installed, otherwise a fake that prints a pbkdf2-shaped hash.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/setup-host-console.sh"
OBS="$ROOT/scripts/setup-observability.sh"
TMP="/tmp/datagate-console-smoke-$$"
FAIL=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; FAIL=1; }

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

# Fresh sandbox per scenario: Ubuntu-like /etc/pam.d/login, /etc/grub.d/10_linux, fake update-grub.
make_sandbox() {
  rm -rf "$TMP"
  mkdir -p "$TMP/pam.d" "$TMP/grub.d" "$TMP/default/grub.d" "$TMP/boot" "$TMP/profile.d" "$TMP/bin" "$TMP/home/dgadmin"
  cat > "$TMP/pam.d/login" <<'EOF'
# The PAM configuration file for the Shadow `login' service
auth       optional   pam_faildelay.so  delay=3000000
auth [success=ok new_authtok_reqd=ok ignore=ignore user_unknown=bad default=die] pam_securetty.so
auth       requisite  pam_nologin.so
@include common-auth
auth       optional   pam_group.so
@include common-account
@include common-session
@include common-password
EOF
  if [[ -f /etc/grub.d/10_linux ]]; then
    cp /etc/grub.d/10_linux "$TMP/grub.d/10_linux"
  else
    printf '#!/bin/sh\nCLASS="--class gnu-linux --class gnu --class os"\n' > "$TMP/grub.d/10_linux"
  fi
  chmod 0755 "$TMP/grub.d/10_linux"
  printf 'JBSWY3DPEHPK3PXP\n" TOTP_AUTH\n' > "$TMP/home/dgadmin/.google_authenticator"
  printf 'correct-horse-battery-staple\n' > "$TMP/grub.pass"
  printf '# System-wide .bashrc file for interactive bash(1) shells.\n' > "$TMP/bash.bashrc"

  # Fake update-grub that behaves like grub-mkconfig: runs every executable NN_* generator in grub.d
  # (skipping README / *~ / *.dpkg-*); any 10_linux* file emits one Linux entry built from its own CLASS line.
  cat > "$TMP/bin/update-grub" <<'FAKE'
#!/usr/bin/env bash
set -e
T="$DGSC_FAKE_TMP"
[[ -f "$T/fail-update-grub" ]] && exit 1
{
  for gen in "$T"/grub.d/[0-9][0-9]_*; do
    [[ -x "$gen" ]] || continue
    case "$gen" in *~|*.dpkg-*|*README*) continue ;; esac
    case "$(basename "$gen")" in
      10_linux*)
        CLASS=""
        eval "$(grep -m1 '^CLASS=' "$gen")"
        [[ -f "$T/force-restricted" ]] && CLASS="--class gnu-linux --class gnu --class os"
        echo "menuentry 'Ubuntu' --class ubuntu $CLASS \$menuentry_id_option 'gnulinux-simple' {"
        echo "}"
        ;;
      *) "$gen" ;;
    esac
  done
} > "$T/boot/grub.cfg"
FAKE
  chmod +x "$TMP/bin/update-grub"

  if command -v grub-mkpasswd-pbkdf2 >/dev/null 2>&1; then
    MKPASSWD="$(command -v grub-mkpasswd-pbkdf2)"
  else
    printf '#!/bin/sh\ncat >/dev/null\necho "PBKDF2 hash of your password is grub.pbkdf2.sha512.10000.AA.BB"\n' > "$TMP/bin/grub-mkpasswd-pbkdf2"
    chmod +x "$TMP/bin/grub-mkpasswd-pbkdf2"
    MKPASSWD="$TMP/bin/grub-mkpasswd-pbkdf2"
  fi
}

run_script() {
  DGSC_SKIP_ROOT_CHECK=1 \
  DGSC_USER_HOME="${TEST_USER_HOME-$TMP/home/dgadmin}" \
  DGSC_PAM_LOGIN="$TMP/pam.d/login" \
  DGSC_GRUB_D="$TMP/grub.d" \
  DGSC_GRUB_DEFAULT_D="$TMP/default/grub.d" \
  DGSC_GRUB_CFG="$TMP/boot/grub.cfg" \
  DGSC_PROFILE_D="$TMP/profile.d" \
  DGSC_STATE_DIR="$TMP/state" \
  DGSC_GUARD_BIN="$TMP/sbin/datagate-grub-guard" \
  DGSC_APT_CONF_D="$TMP/apt.conf.d" \
  DGSC_BASH_BASHRC="$TMP/bash.bashrc" \
  DGSC_LOGIND_CONF_D="$TMP/logind.conf.d" \
  DGSC_SYSTEMD_VERSION="${TEST_SYSTEMD_VERSION-255}" \
  DGSC_FAKE_TMP="$TMP" \
  DGSC_UPDATE_GRUB="$TMP/bin/update-grub" \
  DGSC_GRUB_MKPASSWD="$MKPASSWD" \
    bash "$SCRIPT" "$@"
}

echo "=== bash -n setup-host-console.sh / setup-observability.sh ==="
if bash -n "$SCRIPT" && bash -n "$OBS"; then pass "bash -n"; else fail "bash -n"; fi

echo "=== scenario: full run (console TOTP + GRUB + idle timeout) ==="
make_sandbox
if run_script --user dgadmin --grub-password-file "$TMP/grub.pass" >"$TMP/out.log" 2>&1; then
  pass "script exits 0"
else
  fail "script failed: $(cat "$TMP/out.log")"
fi
# TOTP line goes right after common-auth (password first, then code) and without nullok.
if awk '/^@include common-auth/ {getline a; getline b; exit !(a ~ /datagate: console TOTP/ && b == "auth required pam_google_authenticator.so")}' "$TMP/pam.d/login"; then
  pass "pam login: TOTP right after common-auth"
else
  fail "pam login: TOTP line missing or misplaced: $(cat "$TMP/pam.d/login")"
fi
if grep -q 'nullok' "$TMP/pam.d/login"; then fail "pam login must not use nullok"; else pass "no nullok (accounts without TOTP are locked out of the console)"; fi
if grep -qE '^CLASS="[^"]*--unrestricted"' "$TMP/grub.d/10_linux"; then pass "10_linux CLASS has --unrestricted"; else fail "10_linux CLASS not unrestricted"; fi
if grep -q 'set superusers="dgsc-grub"' "$TMP/boot/grub.cfg" && grep -q 'password_pbkdf2 dgsc-grub grub.pbkdf2.sha512' "$TMP/boot/grub.cfg"; then
  pass "grub.cfg has superuser + pbkdf2 hash"
else
  fail "grub.cfg missing superuser/hash: $(cat "$TMP/boot/grub.cfg")"
fi
if grep -q 'correct-horse-battery-staple' "$TMP/grub.d/01_datagate_password" "$TMP/boot/grub.cfg" "$TMP/out.log"; then
  fail "plain GRUB password leaked into a file or the log"
else
  pass "plain GRUB password not written anywhere"
fi
if [[ ! -e "$TMP/grub.pass" ]]; then pass "GRUB password file deleted"; else fail "GRUB password file left behind"; fi
if [[ "$(stat -c %a "$TMP/grub.d/01_datagate_password")" == "700" ]]; then pass "01_datagate_password is 0700"; else fail "01_datagate_password mode"; fi
if grep -q 'GRUB_DISABLE_RECOVERY="true"' "$TMP/default/grub.d/99-datagate-recovery.cfg"; then pass "recovery entries disabled"; else fail "recovery not disabled"; fi
idle="$TMP/profile.d/99-datagate-idle-timeout.sh"
if [[ -f "$idle" ]] && [[ "$(bash --norc -i -c "source '$idle'; echo \$TMOUT" 2>/dev/null)" == "600" ]]; then pass "interactive shell: TMOUT=600"; else fail "interactive TMOUT not 600"; fi
if bash --norc -i -c "source '$idle'; TMOUT=0" 2>/dev/null; then fail "TMOUT can be overridden"; else pass "TMOUT is read-only"; fi
if bash --norc -i -c "source '$idle'; source '$idle'; [ \"\$TMOUT\" = 600 ]" 2>/dev/null; then pass "profile.d snippet can be sourced twice"; else fail "sourcing twice breaks the shell"; fi
if sh -i -c ". '$idle'; [ \"\$TMOUT\" = 600 ]" 2>/dev/null </dev/null; then pass "POSIX sh accepts the snippet"; else fail "POSIX sh rejects the snippet"; fi
if [[ "$(bash -c "source '$idle'; echo [\$TMOUT]")" == "[]" ]]; then pass "non-interactive shells (bash -lc, scripts) get no TMOUT"; else fail "TMOUT set in a non-interactive shell"; fi
if [[ "$(bash --norc -i -c "source '$idle'; bash -c 'echo [\$TMOUT]'" 2>/dev/null)" == "[]" ]]; then pass "TMOUT is not exported to child scripts (read builtin unaffected)"; else fail "TMOUT leaks into child processes"; fi

bashrc="$TMP/bash.bashrc"
if grep -q "\. $idle" "$bashrc" && [[ "$(bash --norc -i -c "source '$bashrc'; echo \$TMOUT" 2>/dev/null)" == "600" ]]; then
  pass "nested shells (bash, sudo -s) get TMOUT via bash.bashrc"
else
  fail "bash.bashrc hook missing: $(cat "$bashrc")"
fi
if grep -qx 'StopIdleSessionSec=600' "$TMP/logind.conf.d/99-datagate-idle.conf" && grep -qx '\[Login\]' "$TMP/logind.conf.d/99-datagate-idle.conf"; then
  pass "systemd 255: logind stops idle tty sessions (StopIdleSessionSec=600)"
else
  fail "logind drop-in missing"
fi

echo "=== scenario: re-run is idempotent ==="
cp "$TMP/pam.d/login" "$TMP/login.first"
printf 'correct-horse-battery-staple\n' > "$TMP/grub.pass"
if run_script --user dgadmin --grub-password-file "$TMP/grub.pass" >"$TMP/out.log" 2>&1 \
  && diff -q "$TMP/login.first" "$TMP/pam.d/login" >/dev/null \
  && [[ "$(grep -c -- '--unrestricted' "$TMP/grub.d/10_linux")" -eq 1 ]] \
  && [[ "$(grep -c 'datagate: idle timeout' "$TMP/bash.bashrc")" -eq 1 ]]; then
  pass "second run changes nothing in PAM / bash.bashrc and does not double --unrestricted"
else
  fail "second run not idempotent: $(cat "$TMP/out.log")"
fi

echo "=== scenario: a 10_linux backup must never become a second GRUB generator (found on a real VM) ==="
make_sandbox
cp -p "$TMP/grub.d/10_linux" "$TMP/grub.d/10_linux.dgsc-orig"   # left behind by the first version of this script
if run_script --user dgadmin --grub-password-file "$TMP/grub.pass" >"$TMP/out.log" 2>&1 \
  && [[ ! -e "$TMP/grub.d/10_linux.dgsc-orig" && -f "$TMP/state/10_linux.orig" ]] \
  && [[ "$(grep -c '^menuentry' "$TMP/boot/grub.cfg")" -eq 1 ]] \
  && ! grep '^menuentry' "$TMP/boot/grub.cfg" | grep -qv -- '--unrestricted'; then
  pass "legacy backup moved out of grub.d; the only Linux entry is --unrestricted"
else
  fail "backup in grub.d: $(ls "$TMP/grub.d") / $(cat "$TMP/out.log") / $(cat "$TMP/boot/grub.cfg" 2>/dev/null)"
fi
if ls "$TMP/grub.d" | grep -qvE '^(01_datagate_password|10_linux)$'; then
  fail "unexpected files in grub.d: $(ls "$TMP/grub.d")"
else
  pass "nothing but generators in grub.d"
fi

echo "=== scenario: generated grub.cfg would block unattended boot → rollback ==="
make_sandbox
touch "$TMP/force-restricted"
if run_script --user dgadmin --grub-password-file "$TMP/grub.pass" >"$TMP/out.log" 2>&1; then
  fail "script should fail when boot entries are restricted"
else
  if [[ ! -e "$TMP/grub.d/01_datagate_password" ]] && ! grep -q -- '--unrestricted' "$TMP/grub.d/10_linux"; then
    pass "password script removed and 10_linux restored"
  else
    fail "rollback incomplete"
  fi
fi

echo "=== scenario: update-grub fails → rollback ==="
make_sandbox
touch "$TMP/fail-update-grub"
if run_script --user dgadmin --grub-password-file "$TMP/grub.pass" >"$TMP/out.log" 2>&1; then
  fail "script should fail when update-grub fails"
elif [[ ! -e "$TMP/grub.d/01_datagate_password" ]]; then
  pass "update-grub failure rolls back"
else
  fail "update-grub failure left the password script"
fi

echo "=== scenario: no TOTP enrolled → refuse to lock the console ==="
make_sandbox
rm -f "$TMP/home/dgadmin/.google_authenticator"
if run_script --user dgadmin --skip-grub >"$TMP/out.log" 2>&1; then
  fail "must refuse without .google_authenticator"
elif ! grep -q 'pam_google_authenticator' "$TMP/pam.d/login" && grep -q -- '--no-totp' "$TMP/out.log" \
  && [[ ! -e "$TMP/profile.d/99-datagate-idle-timeout.sh" ]]; then
  pass "refuses (hints at --no-totp) and changes nothing"
else
  fail "PAM/profile changed although TOTP is missing: $(cat "$TMP/out.log")"
fi

echo "=== scenario: host without 2FA (--no-totp) ==="
make_sandbox
rm -f "$TMP/home/dgadmin/.google_authenticator"
cp "$TMP/pam.d/login" "$TMP/login.orig"
if run_script --user dgadmin --no-totp --grub-password-file "$TMP/grub.pass" >"$TMP/out.log" 2>&1 \
  && diff -q "$TMP/login.orig" "$TMP/pam.d/login" >/dev/null \
  && [[ -f "$TMP/grub.d/01_datagate_password" && -f "$TMP/profile.d/99-datagate-idle-timeout.sh" ]]; then
  pass "--no-totp: password-only console, GRUB + idle timeout still applied"
else
  fail "--no-totp fresh run: $(cat "$TMP/out.log")"
fi

echo "=== scenario: switch 2FA → no 2FA keeps the console usable ==="
make_sandbox
cp "$TMP/pam.d/login" "$TMP/login.orig"
run_script --user dgadmin --skip-grub >/dev/null 2>&1
rm -f "$TMP/home/dgadmin/.google_authenticator"   # admin turned SSH 2FA off
if run_script --user dgadmin --no-totp --skip-grub >"$TMP/out.log" 2>&1 \
  && ! grep -q 'pam_google_authenticator\|datagate: console TOTP' "$TMP/pam.d/login" \
  && diff -q "$TMP/login.orig" "$TMP/pam.d/login" >/dev/null; then
  pass "TOTP line removed, the rest of /etc/pam.d/login is exactly as before"
else
  fail "switch to --no-totp: $(cat "$TMP/out.log"); $(diff "$TMP/login.orig" "$TMP/pam.d/login")"
fi
printf 'JBSWY3DPEHPK3PXP\n" TOTP_AUTH\n' > "$TMP/home/dgadmin/.google_authenticator"
if run_script --user dgadmin --skip-grub >/dev/null 2>&1 && [[ "$(grep -c pam_google_authenticator "$TMP/pam.d/login")" -eq 1 ]]; then
  pass "switch back to 2FA adds exactly one TOTP line"
else
  fail "switch back to 2FA"
fi

echo "=== scenario: old systemd (no StopIdleSessionSec) → TMOUT only, clear warning ==="
make_sandbox
if TEST_SYSTEMD_VERSION=249 run_script --user dgadmin --skip-grub >"$TMP/out.log" 2>&1 \
  && [[ ! -e "$TMP/logind.conf.d/99-datagate-idle.conf" ]] && grep -q 'needs 252' "$TMP/out.log"; then
  pass "systemd 249: no logind drop-in, warning printed, script succeeds"
else
  fail "old systemd: $(cat "$TMP/out.log")"
fi

echo "=== scenario: bad input is rejected before anything changes ==="
make_sandbox
cp "$TMP/pam.d/login" "$TMP/login.orig"
printf 'short\n' > "$TMP/grub.pass"
if run_script --user dgadmin --grub-password-file "$TMP/grub.pass" >"$TMP/out.log" 2>&1; then
  fail "short GRUB password accepted"
elif diff -q "$TMP/login.orig" "$TMP/pam.d/login" >/dev/null && [[ ! -e "$TMP/profile.d/99-datagate-idle-timeout.sh" && ! -e "$TMP/grub.d/01_datagate_password" ]]; then
  pass "short GRUB password: error, PAM / GRUB / profile untouched"
else
  fail "short GRUB password changed files before failing"
fi
if TEST_USER_HOME= run_script --user nosuchuser-dgsc --skip-grub >"$TMP/out.log" 2>&1; then
  fail "unknown user accepted"
elif grep -q 'does not exist' "$TMP/out.log" && diff -q "$TMP/login.orig" "$TMP/pam.d/login" >/dev/null; then
  pass "unknown user: clear error, nothing changed"
else
  fail "unknown user: $(cat "$TMP/out.log")"
fi

echo "=== scenario: --skip-grub keeps GRUB untouched ==="
make_sandbox
if run_script --user dgadmin --skip-grub >"$TMP/out.log" 2>&1 \
  && [[ ! -e "$TMP/grub.d/01_datagate_password" ]] \
  && grep -q pam_google_authenticator "$TMP/pam.d/login"; then
  pass "--skip-grub: console TOTP only"
else
  fail "--skip-grub run: $(cat "$TMP/out.log")"
fi

echo "=== scenario: bad args ==="
if run_script --user dgadmin >/dev/null 2>&1; then fail "missing grub option accepted"; else pass "requires --grub-password-file or --skip-grub"; fi
if run_script --user dgadmin --skip-grub --idle-timeout 5 >/dev/null 2>&1; then fail "tiny timeout accepted"; else pass "rejects --idle-timeout < 60"; fi
if bash "$SCRIPT" --user dgadmin --skip-grub >/dev/null 2>&1; then fail "non-root run should die"; else pass "non-root dies with must-be-root"; fi
if run_script --user root --skip-grub >/dev/null 2>&1; then fail "--user root accepted"; else pass "rejects --user root"; fi
if run_script --user dgadmin --skip-grub --grub-password-file "$TMP/grub.pass" >/dev/null 2>&1; then fail "--skip-grub + --grub-password-file accepted"; else pass "--skip-grub and --grub-password-file are exclusive"; fi
if run_script --skip-grub --user 2>"$TMP/err.log" >/dev/null; then fail "--user without value accepted"; elif grep -q -- '--user needs a value' "$TMP/err.log"; then pass "option without value: clear error"; else fail "option without value: $(cat "$TMP/err.log")"; fi
if run_script --user dgadmin --bogus >/dev/null 2>"$TMP/err.log"; then fail "unknown option accepted"; elif grep -q 'unknown arg: --bogus' "$TMP/err.log"; then pass "unknown option: clear error"; else fail "unknown option: $(cat "$TMP/err.log")"; fi

echo "=== scenario: grub package update replaces 10_linux → apt guard restores --unrestricted ==="
make_sandbox
printf 'correct-horse-battery-staple\n' > "$TMP/grub.pass"
run_script --user dgadmin --grub-password-file "$TMP/grub.pass" >/dev/null 2>&1
guard="$TMP/sbin/datagate-grub-guard"
if [[ -x "$guard" ]] && grep -q "$guard" "$TMP/apt.conf.d/99-datagate-grub-guard"; then pass "guard + DPkg::Post-Invoke hook installed"; else fail "guard not installed"; fi
install -m 0755 "$TMP/state/10_linux.orig" "$TMP/grub.d/10_linux"   # package installed its own 10_linux
DGSC_FAKE_TMP="$TMP" "$TMP/bin/update-grub"                # kernel postinst regenerates grub.cfg
if grep '^menuentry' "$TMP/boot/grub.cfg" | grep -qv -- '--unrestricted'; then pass "(precondition) grub.cfg is restricted after the package update"; else fail "precondition"; fi
if DGSC_FAKE_TMP="$TMP" "$guard" 2>/dev/null \
  && grep -qE '^CLASS="[^"]*--unrestricted"' "$TMP/grub.d/10_linux" \
  && ! grep '^menuentry' "$TMP/boot/grub.cfg" | grep -qv -- '--unrestricted' \
  && [[ -f "$TMP/grub.d/01_datagate_password" ]]; then
  pass "guard restored --unrestricted and kept the GRUB password"
else
  fail "guard did not restore unattended boot: $(cat "$TMP/boot/grub.cfg")"
fi
if DGSC_FAKE_TMP="$TMP" "$guard" 2>/dev/null && [[ "$(grep -c -- '--unrestricted' "$TMP/grub.d/10_linux")" -eq 1 ]]; then pass "guard is a no-op when nothing changed"; else fail "guard not idempotent"; fi
install -m 0755 "$TMP/state/10_linux.orig" "$TMP/grub.d/10_linux"
touch "$TMP/fail-update-grub"
if DGSC_FAKE_TMP="$TMP" "$guard" 2>/dev/null && [[ ! -e "$TMP/grub.d/01_datagate_password" ]]; then
  pass "guard drops the GRUB password when it cannot keep boot unattended (and never fails apt)"
else
  fail "guard failure path"
fi

echo "=== scenario: re-run after a package update refreshes the 10_linux backup ==="
make_sandbox
run_script --user dgadmin --grub-password-file "$TMP/grub.pass" >/dev/null 2>&1
install -m 0755 "$TMP/state/10_linux.orig" "$TMP/grub.d/10_linux"
printf '# grub-common 2.12-99 (new upstream)\n' >> "$TMP/grub.d/10_linux"
printf 'correct-horse-battery-staple\n' > "$TMP/grub.pass"
if run_script --user dgadmin --grub-password-file "$TMP/grub.pass" >"$TMP/out.log" 2>&1 \
  && grep -q 'grub-common 2.12-99' "$TMP/state/10_linux.orig"; then
  pass "backup is the current package version, not the stale one"
else
  fail "stale 10_linux backup: $(cat "$TMP/out.log")"
fi

echo "=== wiring: observability calls the console script and sudoers allows it ==="
if grep -q 'setup-host-console.sh" --user "$ADMIN_USER" --grub-password-file' "$OBS" \
  && grep -q 'scripts/setup-host-console.sh$' <(grep 'NOPASSWD' "$OBS" | tr ',' '\n'); then
  pass "setup-observability.sh runs setup-host-console.sh and allows it in sudoers"
else
  fail "setup-observability.sh wiring missing"
fi
# An EXIT trap ending in a skipped `[[ -n "" ]] && rm` made setup-observability.sh exit 1 without a Wazuh password.
for f in "$OBS" "$SCRIPT"; do
  if awk '/^cleanup\(\) \{/ {c=1} c && /^}/ {exit !(prev ~ /return 0/)} c && NF {prev=$0}' "$f"; then
    pass "$(basename "$f"): cleanup trap ends with return 0"
  else
    fail "$(basename "$f"): cleanup trap can leak a non-zero exit code"
  fi
done
if grep -q '^X11Forwarding no' "$ROOT/templates/ssh/sshd_config" && grep -q '^X11Forwarding no' "$ROOT/scripts/setup-host-ssh.sh"; then
  pass "X11Forwarding disabled (template + drop-in)"
else
  fail "X11Forwarding still enabled"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== ALL CONSOLE HARDENING TESTS PASSED ==="
else
  echo "=== CONSOLE HARDENING TESTS FAILED ==="
  exit 1
fi
