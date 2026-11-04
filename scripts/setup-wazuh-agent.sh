#!/usr/bin/env bash
# Wazuh only: safe for a bare database/dashboard host; does not change SSH, disks or applications.
set -euo pipefail
MANAGER="" AGENT_NAME="" VERSION="4.14.5" ROLE="other" PASSWORD_FILE=""
DOCKER_SOURCES_SCRIPT="$(dirname "${BASH_SOURCE[0]}")/../templates/wazuh/wazuh-docker-sources.py"
die() { echo "ERROR: $*" >&2; exit 1; }
need_value() { [[ -n "${2:-}" && "${2:0:2}" != -- ]] || die "$1 needs a value"; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --manager) need_value "$1" "${2:-}"; MANAGER="$2"; shift 2 ;;
    --agent-name) need_value "$1" "${2:-}"; AGENT_NAME="$2"; shift 2 ;;
    --version) need_value "$1" "${2:-}"; VERSION="$2"; shift 2 ;;
    --role) need_value "$1" "${2:-}"; ROLE="$2"; shift 2 ;;
    --password-file) need_value "$1" "${2:-}"; PASSWORD_FILE="$2"; shift 2 ;;
    --docker-sources-script) need_value "$1" "${2:-}"; DOCKER_SOURCES_SCRIPT="$2"; shift 2 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "$MANAGER" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]*$ ]] || die "invalid Wazuh manager address"
[[ "$AGENT_NAME" =~ ^[a-z0-9][a-z0-9._-]{0,62}$ ]] || die "invalid Wazuh agent name"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "invalid Wazuh version"
[[ "$ROLE" =~ ^[a-z][a-z0-9_-]*$ ]] || die "invalid server role"
[[ "$(id -u)" == 0 ]] || die "run as root"
[[ -z "$PASSWORD_FILE" || -s "$PASSWORD_FILE" ]] || die "enrollment password file is missing or empty"
[[ -f "$DOCKER_SOURCES_SCRIPT" ]] || die "Docker source metadata helper is missing"
command -v apt-get >/dev/null || die "automatic Wazuh installation requires a Debian/Ubuntu host"
for init_conf in /etc/ossec-init.conf /var/ossec/etc/ossec-init.conf; do
  [[ ! -f "$init_conf" ]] || ! grep -q 'TYPE="server"' "$init_conf" || die "this host runs a Wazuh manager"
done
export DEBIAN_FRONTEND=noninteractive
apt_opts=(-y -q -o Dpkg::Use-Pty=0 -o DPkg::Lock::Timeout=900)
installed="$(dpkg-query -W -f='${Version}' wazuh-agent 2>/dev/null || true)"
if [[ -n "$installed" ]] && dpkg --compare-versions "$installed" gt "${VERSION}-999"; then
  die "installed wazuh-agent ${installed} is newer than configured ${VERSION}; reconcile manager/agent versions before continuing"
fi
if [[ "$installed" != "$VERSION"-* ]]; then
  apt-get update -q -o DPkg::Lock::Timeout=900
  apt-get install "${apt_opts[@]}" curl ca-certificates gnupg python3
  install -d -m 0755 /usr/share/keyrings
  keyfile="$(mktemp)"
  trap 'rm -f "$keyfile"' EXIT
  curl -fsSL --retry 3 https://packages.wazuh.com/key/GPG-KEY-WAZUH | gpg --batch --yes --dearmor -o "$keyfile"
  install -m 0644 "$keyfile" /usr/share/keyrings/wazuh.gpg
  printf '%s\n' 'deb [signed-by=/usr/share/keyrings/wazuh.gpg] https://packages.wazuh.com/4.x/apt/ stable main' > /etc/apt/sources.list.d/wazuh.list
  apt-get update -q -o DPkg::Lock::Timeout=900
  package_version="$(apt-cache madison wazuh-agent | awk -v want="${VERSION}-" '!v && index($3,want)==1 {v=$3} END {print v}')"
  [[ -n "$package_version" ]] || die "wazuh-agent ${VERSION} is unavailable"
  WAZUH_MANAGER="$MANAGER" WAZUH_AGENT_NAME="$AGENT_NAME" apt-get install "${apt_opts[@]}" --allow-change-held-packages "wazuh-agent=$package_version"
  rm -f "$keyfile"
  trap - EXIT
fi
command -v python3 >/dev/null || apt-get install "${apt_opts[@]}" python3
apt-mark hold wazuh-agent >/dev/null

conf=/var/ossec/etc/ossec.conf
[[ -f "$conf" ]] || die "Wazuh configuration is missing"
if [[ -s /var/ossec/etc/client.keys ]]; then
  registered="$(awk 'NR==1 {print $2}' /var/ossec/etc/client.keys)"
  [[ "$registered" == "$AGENT_NAME" ]] || die "agent is registered as ${registered}; reconcile its identity before renaming to ${AGENT_NAME}"
fi
if [[ -n "$PASSWORD_FILE" ]]; then
  install -o root -g wazuh -m 0640 "$PASSWORD_FILE" /var/ossec/etc/authd.pass
fi
docker_root=/var/lib/docker
if command -v docker >/dev/null; then
  detected="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  [[ -z "$detected" ]] || docker_root="$detected"
fi
backup="$(mktemp /var/ossec/etc/ossec.conf.dgsc-backup.XXXXXX)"
cp -p "$conf" "$backup"
python3 - "$MANAGER" "$AGENT_NAME" "$ROLE" "$docker_root" <<'PY'
import os, pathlib, sys, tempfile, xml.etree.ElementTree as ET
manager, name, role, docker_root = sys.argv[1:]
path = pathlib.Path('/var/ossec/etc/ossec.conf')
text = path.read_text()
root = ET.fromstring('<root>' + text + '</root>')
config = root.find('ossec_config')
if config is None:
    raise SystemExit('ERROR: ossec_config is missing')
client = config.find('client')
if client is None:
    raise SystemExit('ERROR: client configuration is missing')
def value(parent, tag, text):
    node = parent.find(tag)
    if node is None: node = ET.SubElement(parent, tag)
    node.text = text
server = client.find('server')
if server is None: server = ET.SubElement(client, 'server')
value(server, 'address', manager)
value(server, 'port', '1514')
value(server, 'protocol', 'tcp')
enrollment = client.find('enrollment')
if enrollment is None: enrollment = ET.SubElement(client, 'enrollment')
value(enrollment, 'enabled', 'yes')
value(enrollment, 'manager_address', manager)
value(enrollment, 'agent_name', name)
value(enrollment, 'port', '1515')
if pathlib.Path('/var/ossec/etc/authd.pass').exists():
    value(enrollment, 'authorization_pass_path', 'etc/authd.pass')
labels = config.find('labels')
if labels is None: labels = ET.SubElement(config, 'labels')
label = next((n for n in labels.findall('label') if n.get('key') == 'datagate.role'), None)
if label is None: label = ET.SubElement(labels, 'label', {'key': 'datagate.role'})
label.text = role
# One Docker source per root. Keep pre-existing equivalent sources rather than reading files twice.
location = str(pathlib.Path(docker_root) / 'containers/*/*-json.log')
equivalent = {str(pathlib.Path(p).resolve()) for p in [location, str(pathlib.Path(docker_root) / 'containers/*/*.log')]}
if not any(str(pathlib.Path(n.findtext('location')).resolve()) in equivalent
           for c in root for n in c.findall('localfile') if n.findtext('location')):
    local = ET.SubElement(config, 'localfile')
    value(local, 'log_format', 'json')
    value(local, 'location', location)
ET.indent(root, space='  ')
output = '\n'.join(ET.tostring(c, encoding='unicode') for c in root) + '\n'
if output != text:
    stat = path.stat()
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix='.ossec.conf.dgsc-')
    try:
        with os.fdopen(fd, 'w') as f: f.write(output)
        os.chmod(tmp, stat.st_mode & 0o777)
        os.chown(tmp, stat.st_uid, stat.st_gid)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
print('Wazuh source: ' + location)
PY
if ! /var/ossec/bin/wazuh-agentd -t || ! /var/ossec/bin/wazuh-logcollector -t; then
  cp -p "$backup" "$conf"
  die "Wazuh rejected its configuration; previous configuration restored"
fi
install -d -m 0755 /usr/local/lib/datagate
install -m 0755 "$DOCKER_SOURCES_SCRIPT" /usr/local/lib/datagate/wazuh-docker-sources.py.new
mv -f /usr/local/lib/datagate/wazuh-docker-sources.py.new /usr/local/lib/datagate/wazuh-docker-sources.py
python3 /usr/local/lib/datagate/wazuh-docker-sources.py --no-restart
cat > /etc/systemd/system/datagate-wazuh-docker-sources.service <<'EOF'
[Unit]
Description=Refresh Wazuh Docker log names and Compose labels
After=docker.service wazuh-agent.service
[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/lib/datagate/wazuh-docker-sources.py
EOF
cat > /etc/systemd/system/datagate-wazuh-docker-sources.timer <<'EOF'
[Unit]
Description=Refresh Wazuh sources after Docker container changes
[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
RandomizedDelaySec=5s
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable wazuh-agent
state_before="$(stat -c '%y' /var/ossec/var/run/wazuh-agentd.state 2>/dev/null || true)"
systemctl restart wazuh-agent
for ((attempt=0; attempt<45; attempt++)); do
  state_now="$(stat -c '%y' /var/ossec/var/run/wazuh-agentd.state 2>/dev/null || true)"
  if [[ -n "$state_now" && "$state_now" != "$state_before" ]] &&
      systemctl is-active --quiet wazuh-agent &&
      grep -Eq "^status='connected'" /var/ossec/var/run/wazuh-agentd.state 2>/dev/null; then
    systemctl enable --now datagate-wazuh-docker-sources.timer
    echo "Wazuh agent ${AGENT_NAME} connected to ${MANAGER}; role=${ROLE}; Docker log collection configured"
    exit 0
  fi
  sleep 2
done
die "Wazuh agent did not connect to ${MANAGER} within 90 seconds; check enrollment, ports 1514/1515 and /var/ossec/logs/ossec.log"
