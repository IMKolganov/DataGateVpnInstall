#!/usr/bin/env bash
# Load OpenVPN DCO kernel module on the host (required when DCO=true in containers).
# OpenVPN 2.7 + Linux 6.16+ use in-tree "ovpn"; older kernels use ovpn-dco-v2.
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

# ovpn = in-tree (Ubuntu resolute / kernel 6.16+); ovpn-dco* = out-of-tree
CANDIDATES=(ovpn ovpn-dco-v2 ovpn_dco_v2 ovpn-dco ovpn_dco)

for m in "${CANDIDATES[@]}"; do
  if mod_loaded "$m" || try_modprobe "$m"; then
    info "DCO module ready ($m)"
    lsmod | grep -E 'ovpn' || true
    exit 0
  fi
done

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
  else
    warn "linux-modules-extra-${kver} not available (normal on kernels with in-tree ovpn)"
  fi
fi

if lsmod 2>/dev/null | awk '{print $1}' | grep -qE '^ovpn'; then
  info "DCO-related module already loaded:"
  lsmod | grep -E 'ovpn' || true
  exit 0
fi

warn "ovpn / ovpn-dco module not found — OpenVPN will fall back to userspace (slower)."
warn "On Linux 6.16+: modprobe ovpn (in-tree). On older: linux-modules-extra or DKMS ovpn-dco-v2."
warn "Containers keep DCO=true; without the module OpenVPN continues in userspace."
exit 0
