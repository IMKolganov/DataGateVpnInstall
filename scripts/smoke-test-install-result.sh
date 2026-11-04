#!/usr/bin/env bash
# Check installer exit status without starting containers or changing the host.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/datagate-install-result.XXXXXX)"
trap 'rm -rf "$TEST_DIR"' EXIT

cat >"$TEST_DIR/post-install-check.sh" <<'EOF'
#!/usr/bin/env bash
echo "checked $ENV_FILE"
exit "$CHECK_EXIT"
EOF
chmod +x "$TEST_DIR/post-install-check.sh"

run_result() {
  ROOT="$ROOT" TEST_DIR="$TEST_DIR" CHECK_EXIT="$1" TEST_RENDER_ONLY="${2:-0}" \
    TEST_SKIP_START="${3:-0}" TEST_START_STACKS="${4:-true}" bash -c '
    set --
    source "$ROOT/scripts/install-vpn-host.sh"
    SCRIPT_DIR="$TEST_DIR"
    INSTALL_HOME="$TEST_DIR/home"
    INSTALL_OPENVPN_UDP=false
    INSTALL_OPENVPN_TCP=false
    INSTALL_XRAY=true
    RENDER_ONLY="$TEST_RENDER_ONLY"
    SKIP_START="$TEST_SKIP_START"
    START_STACKS="$TEST_START_STACKS"
    run_post_install_check
    echo "installation finished"
  ' >"$TEST_DIR/output" 2>&1
}

run_result 0
grep -Fq "checked $TEST_DIR/home/site.env" "$TEST_DIR/output"
grep -Fq 'installation finished' "$TEST_DIR/output"
echo 'PASS: successful post-install checks allow installation to finish'

if run_result 1; then
  echo 'FAIL: a failed Xray post-install check reported a successful installation' >&2
  exit 1
fi
grep -Fq 'post-install checks failed' "$TEST_DIR/output"
if grep -Fq 'installation finished' "$TEST_DIR/output"; then
  echo 'FAIL: installation continued after a failed post-install check' >&2
  exit 1
fi
echo 'PASS: failed post-install checks fail installation'

for mode in render-only skip-start start-stacks-false; do
  case "$mode" in
    render-only) run_result 1 1 0 true ;;
    skip-start) run_result 1 0 1 true ;;
    start-stacks-false) run_result 1 0 0 false ;;
  esac
  if grep -Fq 'checked ' "$TEST_DIR/output"; then
    echo "FAIL: post-install checks ran with $mode" >&2
    exit 1
  fi
  grep -Fq 'installation finished' "$TEST_DIR/output"
  echo "PASS: post-install checks are skipped with $mode"
done
