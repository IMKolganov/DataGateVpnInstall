#!/usr/bin/env bash
# No host changes, published ports, application images or real secrets. Optional nginx syntax check uses a local image.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d /tmp/datagate-dashboard-test.XXXXXX)"
trap 'if [[ "${DASHBOARD_TEST_KEEP:-0}" != 1 ]]; then rm -rf "$work"; fi' EXIT
export DASHBOARD_TEST_ROOT="$work"
python3 - <<'PY'
import os, pathlib, shlex
root = pathlib.Path(os.environ['DASHBOARD_TEST_ROOT'])
values = dict(PUBLIC_IP='203.0.113.50', INSTALL_HOME=str(root / 'full'), CERTBOT_EMAIL='test@datagateapp.com',
    DASHBOARD_DOMAIN='dash.datagateapp.com', API_DOMAIN='api.datagateapp.com', TG_DOMAIN='tg.datagateapp.com',
    LANDING_DOMAINS='datagateapp.com www.datagateapp.com', ADMIN_SSH_IP='192.0.2.20', ADMIN_USER='dashboardadmin',
    WAZUH_MANAGER='192.0.2.30', PROMETHEUS_IP='192.0.2.40', JWT_SECRET='test-32-character-random-secret-abcdef',
    DB_CONNECTION_STRING_DATAGATE='Host=db;Password=literal${SHOULD_NOT_EXPAND}#"with spaces', TELEGRAMBOT_BOT_TOKEN='test-bot-token',
    DASHBOARDAPI_CLIENTID='test-bot', DASHBOARDAPI_CLIENTSECRET='literal${SHOULD_NOT_EXPAND}#"with spaces',
    EmailSender__Host='CHANGE_ME', EmailSender__Username='YOUR_SMTP_USER', EmailSender__Password='CHANGE_ME')
def write(name, data):
    (root / name).write_text(''.join(f'{key}={shlex.quote(value)}\n' for key, value in data.items()))
write('full.env', values)
write('draft.env', {**values, 'INSTALL_HOME':str(root/'draft'), 'JWT_SECRET':'', 'DB_CONNECTION_STRING_DATAGATE':'', 'TELEGRAMBOT_BOT_TOKEN':'CHANGE_ME'})
write('minimal.env', {**values, 'INSTALL_HOME':str(root/'minimal'), 'TG_DOMAIN':'', 'LANDING_DOMAINS':'',
    'TELEGRAMBOT_BOT_TOKEN':'', 'DASHBOARDAPI_CLIENTID':'', 'DASHBOARDAPI_CLIENTSECRET':'', 'DASHBOARD_DOMAIN':values['API_DOMAIN']})
write('bad.env', {**values, 'INSTALL_HOME':str(root/'bad'), 'TG_DOMAIN':values['API_DOMAIN']})
PY

bash -n "$ROOT/scripts/install-dashboard-host.sh"
if command -v shellcheck >/dev/null; then shellcheck "$ROOT/scripts/install-dashboard-host.sh"; fi
bash "$ROOT/scripts/install-dashboard-host.sh" --env "$work/full.env" --render-only
bash "$ROOT/scripts/install-dashboard-host.sh" --env "$work/minimal.env" --render-only
bash "$ROOT/scripts/install-dashboard-host.sh" --env "$work/draft.env" --render-draft-only
[[ -f "$work/draft/datagate-monitor/backend.env" && -f "$work/draft/dashboard.env" ]]
if bash "$ROOT/scripts/install-dashboard-host.sh" --env "$work/bad.env" --render-only >"$work/invalid.log" 2>&1; then
  echo 'FAIL: duplicate domain accepted' >&2; exit 1
fi
[[ ! -d "$work/bad" ]] || { echo 'FAIL: invalid input wrote output' >&2; exit 1; }
[[ ! -d "$work/minimal/datagate-monitor-telegrambot" && ! -d "$work/minimal/datagate-landing" ]]
[[ "$(stat -c '%a' "$work/full/datagate-monitor/backend.env")" == 600 ]]
[[ "$(stat -c '%a' "$work/full")" == 700 ]]
printf 'preserve on rerender\n' >"$work/full/datagate-monitor/resources/test-existing-data"
bash "$ROOT/scripts/install-dashboard-host.sh" --env "$work/full.env" --render-only
[[ -f "$work/full/datagate-monitor/resources/test-existing-data" ]]

if command -v docker >/dev/null && docker compose version >/dev/null 2>&1; then
  for stack in datagate-monitor datagate-monitor-telegrambot datagate-landing nginx-docker; do
    # Create an empty build context: config validates without cloning or building the landing.
    mkdir -p "$work/full/datagate-landing/source"
    docker compose --project-directory "$work/full/$stack" config --format json >"$work/$stack.json"
  done
  python3 - <<'PY'
import json, os, pathlib
root = pathlib.Path(os.environ['DASHBOARD_TEST_ROOT'])
for name in ('datagate-monitor', 'datagate-monitor-telegrambot', 'datagate-landing'):
    data = json.loads((root / f'{name}.json').read_text())
    assert all(not service.get('ports') for service in data['services'].values()), name
backend = json.loads((root / 'datagate-monitor.json').read_text())['services']['backend']
assert backend['environment']['DB_CONNECTION_STRING_DATAGATE'].replace('$$', '$') == 'Host=db;Password=literal${SHOULD_NOT_EXPAND}#"with spaces'
assert backend['environment']['ConnectionStrings__Redis'] == 'redis:6379'
assert backend['environment']['EmailSender__Host'] == 'CHANGE_ME'
bot = json.loads((root / 'datagate-monitor-telegrambot.json').read_text())['services']['telegrambot']
assert bot['environment']['DASHBOARDAPI_CLIENTSECRET'].replace('$$', '$') == 'literal${SHOULD_NOT_EXPAND}#"with spaces'
assert bot['environment']['TELEGRAMBOT_PORT'] == '443'
assert bot['environment']['TELEGRAMBOT_LISTEN_PORT'] == '5050'
assert bot['environment']['USE_CERTIFICATE'] == 'false'
assert bot['environment']['DASHBOARDAPI_URL'] == 'http://backend:5581/api'
assert {str(p['published']) for p in json.loads((root/'nginx-docker.json').read_text())['services']['nginx']['ports']} == {'80','443'}
print('PASS: Compose, private service ports, raw secrets and Telegram webhook listener')
PY
  image="${DASHBOARD_TEST_NGINX_IMAGE:-datagateservercontrol-frontend:latest}"
  if docker image inspect "$image" >/dev/null 2>&1; then
    nginx_test() {
      docker run --rm --network none --entrypoint nginx \
        -v "$work/full/nginx-docker/conf.d:/etc/nginx/conf.d:ro" \
        -v "$work/full/nginx-docker/certbot/conf:/etc/letsencrypt:ro" "$image" -t
    }
    nginx_test
    for d in api.datagateapp.com dash.datagateapp.com tg.datagateapp.com datagateapp.com; do
      mkdir -p "$work/full/nginx-docker/certbot/conf/live/$d"
      openssl req -x509 -nodes -newkey rsa:2048 -days 1 -subj "/CN=$d" \
        -keyout "$work/full/nginx-docker/certbot/conf/live/$d/privkey.pem" \
        -out "$work/full/nginx-docker/certbot/conf/live/$d/fullchain.pem" 2>/dev/null
    done
    bash "$ROOT/scripts/install-dashboard-host.sh" --env "$work/full.env" --render-only
    nginx_test
    echo 'PASS: nginx HTTP bootstrap and HTTPS config'
  else echo "SKIP: nginx syntax check (no local $image; set DASHBOARD_TEST_NGINX_IMAGE)"; fi
else echo 'SKIP: Docker Compose checks (not installed)'; fi
echo 'DASHBOARD SMOKE TEST OK'
