#!/usr/bin/env bash
# Non-root scenario tests for setup-host-ssh.sh footguns (no apt/sshd).
# Catches the dg-vpn-nor-1 failure: --pubkey == user's authorized_keys → install same-file abort.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SSH_SCRIPT="$ROOT/scripts/setup-host-ssh.sh"
TMP="/tmp/datagate-ssh-smoke-$$"
FAIL=0

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; FAIL=1; }

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

mkdir -p "$TMP/home/admin/.ssh" "$TMP/home/other/.ssh" "$TMP/keys"
echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA smoke@test' \
  >"$TMP/home/admin/.ssh/authorized_keys"
echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB other@test' \
  >"$TMP/home/other/.ssh/authorized_keys"
echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC file@test' \
  >"$TMP/keys/id_ed25519.pub"
chmod 700 "$TMP/home/admin/.ssh" "$TMP/home/other/.ssh"
chmod 600 "$TMP/home/admin/.ssh/authorized_keys" "$TMP/home/other/.ssh/authorized_keys"

# Mirror install_authorized_keys logic from setup-host-ssh.sh (keep in sync).
install_authorized_keys_logic() {
  local u="$1" key_src="$2" home="$3"
  local dest="$home/.ssh/authorized_keys"
  mkdir -p "$home/.ssh"
  chmod 0700 "$home/.ssh"
  grep -qE '^(ssh-|ecdsa-)' "$key_src" || return 1
  if [[ -f "$dest" ]] && [[ "$(realpath -m "$key_src")" == "$(realpath -m "$dest")" ]]; then
    chmod 0600 "$dest"
    return 0
  fi
  install -m 0600 "$key_src" "$dest"
}

echo "=== bash -n setup-host-ssh.sh ==="
if bash -n "$SSH_SCRIPT"; then
  pass "bash -n"
else
  fail "bash -n"
fi

echo "=== scenario: --pubkey is already authorized_keys (nor-1 footgun) ==="
before=$(sha256sum "$TMP/home/admin/.ssh/authorized_keys" | awk '{print $1}')
if install_authorized_keys_logic admin "$TMP/home/admin/.ssh/authorized_keys" "$TMP/home/admin"; then
  after=$(sha256sum "$TMP/home/admin/.ssh/authorized_keys" | awk '{print $1}')
  if [[ "$before" == "$after" ]]; then
    pass "same-file pubkey is no-op (no install abort)"
  else
    fail "same-file path mutated authorized_keys"
  fi
else
  fail "same-file pubkey logic returned error"
fi

# Old broken behaviour: plain install onto self must fail — document that we avoid it
if install -m 0600 "$TMP/home/admin/.ssh/authorized_keys" "$TMP/home/admin/.ssh/authorized_keys" 2>/dev/null; then
  fail "unexpected: raw install same-file succeeded (platform-dependent)"
else
  pass "raw install same-file fails (why script must special-case)"
fi

echo "=== scenario: copy from separate .pub file ==="
if install_authorized_keys_logic admin "$TMP/keys/id_ed25519.pub" "$TMP/home/admin"; then
  if grep -q 'file@test' "$TMP/home/admin/.ssh/authorized_keys"; then
    pass "copy from .pub file"
  else
    fail "copy from .pub did not update keys"
  fi
else
  fail "copy from .pub"
fi

echo "=== scenario: pubkey-from-user other ==="
# restore admin key then copy from other
cp "$TMP/keys/id_ed25519.pub" "$TMP/home/admin/.ssh/authorized_keys"
if install_authorized_keys_logic admin "$TMP/home/other/.ssh/authorized_keys" "$TMP/home/admin"; then
  if grep -q 'other@test' "$TMP/home/admin/.ssh/authorized_keys"; then
    pass "pubkey-from-user path"
  else
    fail "pubkey-from-user content wrong"
  fi
else
  fail "pubkey-from-user"
fi

echo "=== script help / flags parse (non-root must die cleanly) ==="
if bash "$SSH_SCRIPT" --help >/dev/null; then
  pass "--help exits 0"
else
  fail "--help"
fi
if bash "$SSH_SCRIPT" --user admin --skip-password 2>/dev/null; then
  fail "non-root run should die"
else
  pass "non-root dies with must-be-root"
fi

# Script source must contain the same-file guard (regression lock)
if grep -q 'realpath -m' "$SSH_SCRIPT" && grep -q 'already in place' "$SSH_SCRIPT"; then
  pass "setup-host-ssh.sh has same-file guard"
else
  fail "setup-host-ssh.sh missing same-file guard"
fi

if [[ "$FAIL" -eq 0 ]]; then
  echo "=== ALL SSH SCENARIO TESTS PASSED ==="
else
  echo "=== SSH SCENARIO TESTS FAILED ==="
  exit 1
fi
