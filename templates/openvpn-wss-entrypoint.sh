#!/usr/bin/env bash
# Keep the existing image entrypoint and manager restarts, but bind raw VPN sockets to loopback.
set -euo pipefail

configure_openvpn_loopback() {
  local runtime_dir="$1" binary
  binary="$(command -v openvpn)"
  [[ -x "$binary" ]] || { echo 'ERROR: OpenVPN binary not found' >&2; return 1; }
  mkdir -p "$runtime_dir"
  ln -sfn "$binary" "$runtime_dir/openvpn-real"
  cat >"$runtime_dir/openvpn" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
config_files=()
arguments=("$@")
for ((i=0; i<${#arguments[@]}; i++)); do
  case "${arguments[i]}" in
    --config)
      [[ $((i+1)) -lt ${#arguments[@]} ]] || { echo 'ERROR: --config needs a path' >&2; exit 1; }
      config_files+=("${arguments[i+1]}")
      i=$((i+1))
      ;;
    --config=*) config_files+=("${arguments[i]#--config=}") ;;
    --local|--local=*)
      echo 'ERROR: WSS-only controls --local; remove the explicit bind override' >&2; exit 1 ;;
  esac
done
if [[ ${#config_files[@]} -gt 0 ]]; then
  for config in "${config_files[@]}"; do
    [[ -r "$config" ]] || { echo 'ERROR: OpenVPN configuration is not readable' >&2; exit 1; }
    # OpenVPN server mode can accumulate multiple local addresses instead of overriding them.
    # Reject bind overrides/includes rather than risk starting a public listener beside loopback.
    if grep -Eq '^[[:space:]]*(--)?(local|config)([[:space:]]|=)' "$config"; then
      echo 'ERROR: WSS-only requires a configuration without local directives or config includes' >&2; exit 1
    fi
  done
  exec "${BASH_SOURCE[0]%/*}/openvpn-real" "$@" --local 127.0.0.1
fi
# Key generation, version checks and other non-server commands keep their original arguments.
exec "${BASH_SOURCE[0]%/*}/openvpn-real" "$@"
WRAPPER
  chmod 755 "$runtime_dir/openvpn"
  export PATH="$runtime_dir:$PATH"
}

configure_openvpn_wss() {
  case "${OPENVPN_WSS_ONLY:-true}" in
    true|TRUE|yes|YES|1|on|ON) configure_openvpn_loopback "$1" ;;
    false|FALSE|no|NO|0|off|OFF) ;;
    *) echo 'ERROR: OPENVPN_WSS_ONLY must be true or false' >&2; return 1 ;;
  esac
}

main() {
  configure_openvpn_wss /run/dgsc-openvpn
  exec /entrypoint.sh "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
