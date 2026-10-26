#!/usr/bin/env bash
# Real-root scenario tests for setup-host-ssh.sh + setup-host-console.sh in a throwaway ubuntu:24.04 container:
# real sshd (sshd -t / sshd -T), real PAM (pamtester on the "login" service = UpCloud console), real apt.
# GRUB is skipped here (no bootloader in a container) — it is covered by smoke-test-console-hardening.sh.
#
#   ./scripts/docker-test-ssh-console.sh            # needs docker + network for apt inside the container
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="${DGSC_TEST_IMAGE:-ubuntu:24.04}"

if [[ "${1:-}" != "--inner" ]]; then
  command -v docker >/dev/null 2>&1 || { echo "SKIP: docker not available"; exit 0; }
  exec docker run --rm -v "$ROOT:/kit:ro" "$IMAGE" bash /kit/scripts/docker-test-ssh-console.sh --inner
fi

# ------------------------------------------------------------------ inside the container (root) --------
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }
SSH=/kit/scripts/setup-host-ssh.sh
CONSOLE=/kit/scripts/setup-host-console.sh
W=/work
mkdir -p "$W"

echo "=== preparing container (apt) ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq openssh-server libpam-google-authenticator pamtester oathtool sudo >/dev/null
mkdir -p /run/sshd

SECRET="$(head -c 20 /dev/urandom | base32 | tr -d '=')"
printf '%s\n' "$SECRET" > "$W/totp"
printf 'Sudo-Pass-%s\n' "$(head -c 6 /dev/urandom | od -An -tx1 | tr -d ' \n')" > "$W/pass"
PASS_TXT="$(cat "$W/pass")"
ssh-keygen -q -t ed25519 -N '' -f "$W/key"
cp "$W/key.pub" "$W/key.pub.keep"

eff() { sshd -T 2>/dev/null | awk -v k="$1" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }'; }
# Console login through PAM "login": password, then (when asked) the code. Exit 0 = shell would open.
console_login() { printf '%s\n%s\n' "$2" "${3:-}" | pamtester -I tty=ttyS0 login "$1" authenticate >/dev/null 2>&1; }
code_at() { oathtool --totp -b "$SECRET" -N "$1"; }

echo "=== 1) fresh host, SSH 2FA (what the dashboard does) ==="
out="$(bash "$SSH" --user dgadmin --pubkey "$W/key.pub" --password-file "$W/pass" --totp-secret-file "$W/totp" --totp-out "$W/totp.out" 2>&1)" \
  && pass "setup-host-ssh.sh exits 0" || fail "setup-host-ssh.sh failed: $out"
[[ "$(eff authenticationmethods)" == "publickey,keyboard-interactive" ]] && pass "sshd: key + TOTP" || fail "sshd authenticationmethods=$(eff authenticationmethods)"
[[ "$(eff permitrootlogin)" == "no" && "$(eff passwordauthentication)" == "no" && "$(eff x11forwarding)" == "no" ]] \
  && pass "sshd: no root, no password, no X11" || fail "sshd root=$(eff permitrootlogin) pw=$(eff passwordauthentication) x11=$(eff x11forwarding)"
[[ "$(cat "$W/totp.out")" == "$SECRET" ]] && pass "--totp-out reports the enrolled secret" || fail "totp-out mismatch"
[[ "$(stat -c '%U %a' /home/dgadmin/.google_authenticator)" == "dgadmin 400" ]] && pass "TOTP file owned by dgadmin, 0400" || fail "TOTP file perms"

echo "=== 2) console with 2FA ==="
cp /etc/pam.d/login "$W/login.orig"
out="$(bash "$CONSOLE" --user dgadmin --skip-grub 2>&1)" && pass "setup-host-console.sh exits 0" || fail "console failed: $out"
console_login dgadmin "$PASS_TXT" "$(code_at now)" && pass "console: password + right code → in" || fail "console: right code rejected"
console_login dgadmin "$PASS_TXT" "000000" && fail "console: wrong code accepted" || pass "console: wrong code → refused"
console_login dgadmin "wrong-password" "$(code_at '+30 seconds')" && fail "console: wrong password accepted" || pass "console: wrong password → refused"
useradd -m -s /bin/bash notp && echo 'notp:Notp-Test-Pass-1' | chpasswd
console_login notp "Notp-Test-Pass-1" "123456" && fail "console: user without TOTP got in" || pass "console: user without TOTP → refused"
echo 'root:Root-Test-Pass-1' | chpasswd
console_login root "Root-Test-Pass-1" "123456" && fail "console: root got in" || pass "console: root → refused"

echo "=== 3) re-run with apt mirrors unreachable (re-install / reset on a host without internet) ==="
echo 'Acquire::http::Proxy "http://127.0.0.1:9/"; Acquire::https::Proxy "http://127.0.0.1:9/";' > /etc/apt/apt.conf.d/99-dead-proxy
out="$(bash "$SSH" --user dgadmin --skip-password --totp-secret-file "$W/totp" --totp-out "$W/totp.out" 2>&1)" \
  && pass "re-run succeeds without apt" || fail "re-run needs apt: $out"
mv /home/dgadmin/.google_authenticator "$W/ga.keep"
# fresh package install with dead mirrors must fail cleanly and change nothing
apt-get remove -y -qq libpam-google-authenticator >/dev/null 2>&1
before="$(sha256sum /etc/ssh/sshd_config /etc/pam.d/sshd | sha256sum)"
out="$(bash "$SSH" --user dgadmin --skip-password --totp-secret-file "$W/totp" --totp-out "$W/totp.out" 2>&1)" \
  && fail "missing packages + dead apt should fail" \
  || { grep -q 'no changes made' <<<"$out" && [[ "$(sha256sum /etc/ssh/sshd_config /etc/pam.d/sshd | sha256sum)" == "$before" ]] \
       && [[ ! -e /home/dgadmin/.google_authenticator ]] \
       && pass "apt failure: clear error, sshd/PAM/TOTP untouched" || fail "apt failure: $out"; }
rm -f /etc/apt/apt.conf.d/99-dead-proxy
apt-get install -y -qq libpam-google-authenticator >/dev/null
mv "$W/ga.keep" /home/dgadmin/.google_authenticator

echo "=== 4) sshd -t rejects the result → previous config restored ==="
echo 'ThisIsNotAnSshdOption yes' > /etc/ssh/sshd_config.d/50-broken.conf
before="$(cat /etc/ssh/sshd_config /etc/pam.d/sshd /etc/ssh/sshd_config.d/00-datagate-hardening.conf | sha256sum)"
out="$(bash "$SSH" --user dgadmin --apply-sshd-only --skip-totp 2>&1)" \
  && fail "broken sshd config accepted" \
  || { grep -q 'restored' <<<"$out" \
       && [[ "$(cat /etc/ssh/sshd_config /etc/pam.d/sshd /etc/ssh/sshd_config.d/00-datagate-hardening.conf | sha256sum)" == "$before" ]] \
       && pass "sshd -t failure: error + previous files restored" || fail "sshd -t failure: $out"; }
rm -f /etc/ssh/sshd_config.d/50-broken.conf

echo "=== 5) switch the host to NO 2FA ==="
out="$(bash "$SSH" --user dgadmin --apply-sshd-only --skip-totp 2>&1)" && pass "--skip-totp --apply-sshd-only exits 0" || fail "$out"
[[ "$(eff authenticationmethods)" == "publickey" && "$(eff kbdinteractiveauthentication)" == "no" ]] \
  && pass "sshd: key only" || fail "sshd after --skip-totp: $(eff authenticationmethods) / $(eff kbdinteractiveauthentication)"
[[ "$(eff permitrootlogin)" == "no" && "$(eff passwordauthentication)" == "no" ]] && pass "key-only sshd is still hardened" || fail "key-only sshd lost hardening"
out="$(bash "$CONSOLE" --user dgadmin --no-totp --skip-grub 2>&1)" && pass "console --no-totp exits 0" || fail "$out"
console_login dgadmin "$PASS_TXT" "" && pass "console without 2FA: password → in" || fail "console --no-totp still asks for TOTP"
diff -q "$W/login.orig" /etc/pam.d/login >/dev/null && pass "/etc/pam.d/login back to the distro file" || fail "pam login differs: $(diff "$W/login.orig" /etc/pam.d/login)"

echo "=== 6) switch back to 2FA ==="
out="$(bash "$SSH" --user dgadmin --apply-sshd-only 2>&1)" && [[ "$(eff authenticationmethods)" == "publickey,keyboard-interactive" ]] \
  && pass "sshd: key + TOTP again" || fail "$out"
out="$(bash "$CONSOLE" --user dgadmin --skip-grub 2>&1)" || fail "$out"
console_login dgadmin "$PASS_TXT" "" && fail "console accepted password only after re-enabling 2FA" || pass "console requires the code again"

echo "=== 7) fresh user without 2FA from scratch ==="
out="$(bash "$SSH" --user dgnotp --pubkey "$W/key.pub.keep" --password-file "$W/pass" --skip-totp 2>&1)" \
  && [[ ! -e /home/dgnotp/.google_authenticator && "$(eff authenticationmethods)" == "publickey" ]] \
  && pass "--skip-totp: user + keys, no TOTP file, key-only sshd" || fail "fresh --skip-totp: $out"
out="$(bash "$CONSOLE" --user dgnotp --skip-grub 2>&1)" \
  && fail "console 2FA without TOTP file accepted" \
  || { grep -q -- '--no-totp' <<<"$out" && pass "console refuses 2FA without a TOTP file and points to --no-totp" || fail "$out"; }

echo "=== 8) bad input ==="
cp /etc/pam.d/login "$W/login.before"
out="$(bash "$CONSOLE" --user ghost --skip-grub 2>&1)" && fail "unknown user accepted" \
  || { grep -q 'does not exist' <<<"$out" && diff -q "$W/login.before" /etc/pam.d/login >/dev/null && pass "console: unknown user → clear error, nothing changed" || fail "$out"; }
out="$(bash "$SSH" --user root 2>&1)" && fail "ssh --user root accepted" || { grep -q 'do not use root' <<<"$out" && pass "ssh: --user root refused" || fail "$out"; }
printf 'not-base32!\n' > "$W/bad.totp"
out="$(bash "$SSH" --user dgbad --password-file "$W/pass" --pubkey "$W/key.pub.keep" --totp-secret-file "$W/bad.totp" 2>&1)" && fail "bad base32 accepted" \
  || { grep -q 'not base32' <<<"$out" && ! id dgbad >/dev/null 2>&1 \
       && pass "ssh: bad TOTP secret → clear error before creating the user" || fail "$out / user created: $(id dgbad 2>&1)"; }
out="$(bash "$SSH" --user dgbad --password-file "$W/missing.pass" 2>&1)" && fail "missing password file accepted" \
  || { grep -q 'password file not found' <<<"$out" && ! id dgbad >/dev/null 2>&1 && pass "ssh: missing password file → error, no user created" || fail "$out"; }

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== ALL DOCKER SSH/CONSOLE SCENARIOS PASSED ==="
else
  echo "=== DOCKER SSH/CONSOLE SCENARIOS FAILED ==="
  exit 1
fi
