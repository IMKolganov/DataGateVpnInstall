#!/usr/bin/env bash
# Hermetic DNS checks: no network, root, Docker, firewall changes or ACME requests.
# The test variables are consumed by functions in the sourced installer.
# shellcheck disable=SC2034
set -euo pipefail
DNS_TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

run_case() (
  local scenario="$1"
  set --
  source "$DNS_TEST_DIR/install-vpn-host.sh"
  PUBLIC_IP=203.0.113.50
  INSTALL_OPENVPN_UDP=false
  INSTALL_OPENVPN_TCP=false
  INSTALL_XRAY=true
  XRAY_DOMAIN=xs-test.example.com
  HFS_DOMAIN=
  ISSUE_CERTS=true
  START_STACKS=true
  DNS_WAIT_SECONDS=0
  DNS_RETRY_SECONDS=1
  local attempts=0

  getent() {
    local address="$PUBLIC_IP"
    case "$scenario" in
      missing|propagating|timeout) return 2 ;;
      wrong) address=203.0.113.51 ;;
      multiple) printf '%s STREAM\n' 203.0.113.51 ;;
      hfs-missing) [[ "$2" != files.example.com ]] || return 2 ;;
      udp-missing) [[ "$2" != udp.example.com ]] || return 2 ;;
      tcp-missing) [[ "$2" != tcp.example.com ]] || return 2 ;;
      unselected) [[ "$2" == "$XRAY_DOMAIN" ]] || return 2 ;;
    esac
    printf '%s STREAM\n%s DGRAM\n%s RAW\n' "$address" "$address" "$address"
  }
  sleep() {
    attempts=$((attempts + 1))
    if [[ "$scenario" == timeout ]]; then
      SECONDS=$((SECONDS + $1))
      return 0
    fi
    [[ "$scenario" == propagating ]] || { echo 'unexpected sleep'; exit 1; }
    scenario=ready
  }

  case "$scenario" in
    propagating) DNS_WAIT_SECONDS=2 ;;
    timeout) DNS_WAIT_SECONDS=1 ;;
    hfs-missing) HFS_DOMAIN=files.example.com ;;
    udp-only|tcp-only)
      INSTALL_XRAY=false
      if [[ "$scenario" == udp-only ]]; then
        INSTALL_OPENVPN_UDP=true
        UDP_WSS_DOMAIN=udp.example.com
      else
        INSTALL_OPENVPN_TCP=true
        TCP_WSS_DOMAIN=tcp.example.com
      fi
      wait_for_certificate_dns
      exit 0 ;;
    udp-missing|tcp-missing)
      INSTALL_OPENVPN_UDP=true
      INSTALL_OPENVPN_TCP=true
      UDP_WSS_DOMAIN=udp.example.com
      TCP_WSS_DOMAIN=tcp.example.com
      # Exercise DNS independently of the machine's /dev/net/tun.
      wait_for_certificate_dns
      exit 0 ;;
    unselected) UDP_WSS_DOMAIN=udp.example.com; TCP_WSS_DOMAIN=tcp.example.com ;;
    render-only) RENDER_ONLY=1; scenario=missing ;;
    skip-certs) SKIP_CERTS=1; scenario=missing ;;
    skip-start) SKIP_START=1; scenario=missing ;;
    stacks-disabled) START_STACKS=false; scenario=missing ;;
    certs-disabled) ISSUE_CERTS=false; scenario=missing ;;
    skip-preflight) SKIP_PREFLIGHT=1; scenario=missing ;;
    bad-wait) DNS_WAIT_SECONDS=invalid ;;
    bad-retry) DNS_RETRY_SECONDS=0 ;;
  esac
  preflight
  echo "DOWNSTREAM: rendering/stacks/certbot may start (sleeps=$attempts)"
)

expect_success() {
  local output
  if ! output="$(run_case "$1" 2>&1)"; then
    echo "FAIL: $1: $output" >&2; exit 1
  fi
  [[ "$output" == *"$2"* ]] || { echo "FAIL: $1 missing '$2': $output" >&2; exit 1; }
  echo "PASS: $1"
}
expect_failure() {
  local output
  if output="$(run_case "$1" 2>&1)"; then
    echo "FAIL: $1 unexpectedly passed: $output" >&2; exit 1
  fi
  [[ "$output" == *"$2"* && "$output" != *DOWNSTREAM* ]] \
    || { echo "FAIL: $1: $output" >&2; exit 1; }
  echo "PASS: $1 blocks downstream work"
}

expect_success ready 'DNS ready'
expect_success propagating 'sleeps=1'
expect_success unselected 'DNS ready'
expect_success udp-only 'DNS ready'
expect_success tcp-only 'DNS ready'
expect_failure missing 'DNS not ready for xs-test.example.com'
expect_failure timeout 'DNS not ready for xs-test.example.com'
expect_failure wrong '203.0.113.51'
expect_failure multiple 'DNS not ready'
expect_failure hfs-missing 'DNS not ready for files.example.com'
expect_failure udp-missing 'DNS not ready for udp.example.com'
expect_failure tcp-missing 'DNS not ready for tcp.example.com'
expect_failure bad-wait 'DNS_WAIT_SECONDS must'
expect_failure bad-retry 'DNS_RETRY_SECONDS must'
for scenario in render-only skip-certs skip-start stacks-disabled certs-disabled skip-preflight; do
  expect_success "$scenario" DOWNSTREAM
done

echo 'DNS preflight checks passed.'
