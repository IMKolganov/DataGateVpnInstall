#!/usr/bin/env bash
# Load OpenVPN DCO kernel module on the host (required when DCO=true in containers).
# OpenVPN data-channel offload needs ovpn-dco-v2 (or equivalent) in the host kernel.
#
# Usage:
#   sudo ./scripts/setup-ovpn-dco.sh
#
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "[dco] $*"; }
warn() { echo "[dco] WARN: $*" >&2; }

[[ "$(id -u)" -eq 0 ]] || die "run as root"

mod_loaded() {
  lsmod 2>/dev/null | awk '{print $1}' | grep -qx "$1"
}

try_modprobe() {
  local name="$1"
  if modprobe "$name" 2>/dev/null; then
    info "loaded kernel module: $name"
    return 0
  fi
  return 1
}

# Common module names across OpenVPN DCO / kernel builds
CANDIDATES=(ovpn-dco-v2 ovpn_dco_v2 ovpn-dco ovpn_dco)

for m in "${CANDIDATES[@]}"; do
  if mod_loaded "$m" || try_modprobe "$m"; then
    info "DCO module ready ($m)"
    lsmod | grep -E 'ovpn' || true
    exit 0
  fi
done

# Ubuntu/Debian: extra modules often ship DCO
if command -v apt-get >/dev/null 2>&1; then
  kver="$(uname -r)"
  info "trying linux-modules-extra-${kver}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq || true
  if apt-get install -y -qq "linux-modules-extra-${kver}" 2>/dev/null; then
    for m in "${CANDIDATES[@]}"; do
      if try_modprobe "$m"; then
        info "DCO module ready after modules-extra ($m)"
        exit 0
      fi
    done
  fi
fi

warn "ovpn-dco module not found — OpenVPN will fall back to userspace (slower)."
warn "Install kernel headers/DKMS ovpn-dco or linux-modules-extra-\$(uname -r), then: modprobe ovpn-dco-v2"
warn "Containers keep DCO=true; without the module OpenVPN logs a DCO warning and continues."
exit 0
