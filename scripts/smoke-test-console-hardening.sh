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
  DGSC_USER_HOME="$TMP/home/dgadmin" \
  DGSC_PAM_LOGIN="$TMP/pam.d/login" \
  DGSC_GRUB_D="$TMP/grub.d" \
  DGSC_GRUB_DEFAULT_D="$TMP/default/grub.d" \
  DGSC_GRUB_CFG="$TMP/boot/grub.cfg" \
  DGSC_PROFILE_D="$TMP/profile.d" \
  DGSC_STATE_DIR="$TMP/state" \
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
if [[ -f "$idle" ]] && [[ "$(bash -c "source '$idle'; echo \$TMOUT")" == "600" ]]; then pass "TMOUT=600 after sourcing profile.d"; else fail "TMOUT not 600"; fi
if bash -c "source '$idle'; TMOUT=0" 2>/dev/null; then fail "TMOUT can be overridden"; else pass "TMOUT is read-only"; fi
if bash -c "source '$idle'; source '$idle'; [ \"\$TMOUT\" = 600 ]" 2>/dev/null; then pass "profile.d snippet can be sourced twice"; else fail "sourcing twice breaks the shell"; fi
if sh -c ". '$idle'; [ \"\$TMOUT\" = 600 ]" 2>/dev/null; then pass "POSIX sh accepts the snippet"; else fail "POSIX sh rejects the snippet"; fi

echo "=== scenario: re-run is idempotent ==="
cp "$TMP/pam.d/login" "$TMP/login.first"
printf 'correct-horse-battery-staple\n' > "$TMP/grub.pass"
if run_script --user dgadmin --grub-password-file "$TMP/grub.pass" >"$TMP/out.log" 2>&1 \
  && diff -q "$TMP/login.first" "$TMP/pam.d/login" >/dev/null \
  && [[ "$(grep -c -- '--unrestricted' "$TMP/grub.d/10_linux")" -eq 1 ]]; then
  pass "second run changes nothing in PAM and does not double --unrestricted"
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
elif ! grep -q 'pam_google_authenticator' "$TMP/pam.d/login"; then
  pass "refuses and leaves PAM untouched"
else
  fail "PAM changed although TOTP is missing"
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
