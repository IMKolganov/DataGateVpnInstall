#!/usr/bin/env bash
# Hermetic render/firewall/entrypoint checks. No root, live UFW or running containers are touched.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
python3 - "$ROOT" <<'PY'
import json, os, pathlib, shutil, subprocess, sys, tempfile

root = pathlib.Path(sys.argv[1])
def run(args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, check=True, **kwargs)

with tempfile.TemporaryDirectory(prefix='dgsc-wss-only-') as temporary:
    base = pathlib.Path(temporary)
    mock = base / 'mock-bin'
    mock.mkdir()
    def executable(name, text):
        path = mock / name
        path.write_text(text)
        path.chmod(0o755)
    executable('id', '#!/bin/sh\nprintf "0\\n"\n')
    executable('install', '#!/bin/sh\nexit 0\n')
    executable('sysctl', '#!/bin/sh\nexit 0\n')
    executable('ufw', '''#!/usr/bin/env python3
import json, os, sys
with open(os.environ['UFW_COMMAND_LOG'], 'a') as f:
    f.write(json.dumps(sys.argv[1:]) + '\\n')
''')
    executable('openvpn', '''#!/usr/bin/env python3
import json, sys
print(json.dumps(sys.argv[1:]))
''')
    environment = {**os.environ, 'PATH': str(mock) + ':' + os.environ['PATH']}
    environment.pop('OPENVPN_WSS_ONLY', None)
    for label, flag in [('default', None), ('enabled', 'true'), ('disabled', 'false')]:
        home = base / label
        site = base / (label + '.env')
        site.write_text(f'''PUBLIC_IP=203.0.113.50
INSTALL_HOME={home}
WAN_IF=eth0
INSTALL_XRAY=false
BACKEND__BASEURL=https://backend.test/
UDP_WSS_DOMAIN=udp.test
TCP_WSS_DOMAIN=tcp.test
CERTBOT_EMAIL=ops@backend.test
ADMIN_SSH_IP=198.51.100.10
DASHBOARD_API_IP=203.0.113.20
TCP_VPN_SUBNET=10.51.40.0
UDP_VPN_SUBNET=10.51.42.0
PIHOLE_WEBPASSWORD=fixture-password
''' + ('' if flag is None else f'OPENVPN_WSS_ONLY={flag}\n'))
        run(['bash', str(root / 'scripts/install-vpn-host.sh'), '--render-only', '--env', str(site)], env=environment)
        enabled = flag != 'false'
        for stack in ['openvpn-tcp-wss', 'openvpn-udp-wss']:
            stack_home = home / stack
            assert (stack_home / 'wss-entrypoint.sh').is_file()
            assert f'OPENVPN_WSS_ONLY={str(enabled).lower()}' in (stack_home / '.env').read_text()
            if shutil.which('docker'):
                doc = json.loads(run(['docker', 'compose', '--project-directory', str(stack_home),
                    'config', '--format', 'json'], env=environment).stdout)
                service = doc['services'][stack]
                assert service['network_mode'] == 'host'
                assert not service.get('ports'), 'OpenVPN must not publish Docker ports'
                assert service['environment']['OPENVPN_WSS_ONLY'] == str(enabled).lower()
        log = base / (label + '.ufw.jsonl')
        run(['bash', str(root / 'scripts/setup-host-ufw.sh')], env={**environment,
            'ENV_FILE': str(home / 'host/.env'), 'UFW_COMMAND_LOG': str(log)})
        rules = [json.loads(line) for line in log.read_text().splitlines()]
        direct_tcp = any(rule[:2] == ['allow', '1297/tcp'] for rule in rules)
        direct_udp = any(rule[:2] == ['allow', '1194/udp'] for rule in rules)
        direct_api = any('openvpn tcp api dashboard' in rule or 'openvpn udp api dashboard' in rule for rule in rules)
        assert (direct_tcp, direct_udp, direct_api) == (not enabled,) * 3
        assert any(rule[:2] == ['allow', '443/tcp'] for rule in rules)
        assert any('ssh admin' in rule for rule in rules)
        assert any('openvpn tcp api docker' in rule for rule in rules)
        assert any('openvpn udp api docker' in rule for rule in rules)
        assert rules.index(['--force', 'reset']) < rules.index(['--force', 'enable'])

        wrapper_dir = base / (label + '-wrapper')
        config = base / 'server config.conf'
        config.write_text('port 1297\nproto tcp-server\n')
        shell = 'source "$1"; configure_openvpn_wss "$2"; shift 2; openvpn "$@"'
        entrypoint = str(root / 'templates/openvpn-wss-entrypoint.sh')
        for args in [
            ['--config', str(config), '--writepid', 'server.pid'],
            ['--config=' + str(config)],
            ['--genkey', 'secret', 'ta.key'], ['--version'],
        ]:
            result = run(['bash', '-c', shell, 'test', entrypoint, str(wrapper_dir), *args],
                env={**environment, **({} if flag is None else {'OPENVPN_WSS_ONLY': flag})})
            expected = args + (['--local', '127.0.0.1'] if enabled and args[0].startswith('--config') else [])
            assert json.loads(result.stdout) == expected
        assert wrapper_dir.exists() == enabled
        if enabled:
            for body, extra in [('local 0.0.0.0\n', []), ('config nested.conf\n', []), ('', ['--local', '0.0.0.0'])]:
                config.write_text(body)
                result = subprocess.run(['bash', '-c', shell, 'test', entrypoint, str(wrapper_dir), '--config', str(config), *extra],
                    env={**environment, **({} if flag is None else {'OPENVPN_WSS_ONLY': flag})}, text=True, capture_output=True)
                assert result.returncode != 0 and 'ERROR: WSS-only' in result.stderr
        print(f'PASS: {label}: render, no Docker publication, firewall, start/restart, bind-override rejection and key generation')

    bad = base / 'invalid.env'
    bad.write_text(site.read_text().replace('OPENVPN_WSS_ONLY=false', 'OPENVPN_WSS_ONLY=typo'))
    result = subprocess.run(['bash', str(root / 'scripts/install-vpn-host.sh'), '--render-only', '--env', str(bad)],
        env=environment, text=True, capture_output=True)
    assert result.returncode != 0 and 'OPENVPN_WSS_ONLY must be true or false' in result.stderr
    bad_log = base / 'invalid.ufw.jsonl'
    bad_host = base / 'invalid-host.env'
    bad_host.write_text((home / 'host/.env').read_text().replace('OPENVPN_WSS_ONLY=false', 'OPENVPN_WSS_ONLY=typo'))
    result = subprocess.run(['bash', str(root / 'scripts/setup-host-ufw.sh')], env={**environment,
        'ENV_FILE': str(bad_host), 'UFW_COMMAND_LOG': str(bad_log)}, text=True, capture_output=True)
    assert result.returncode != 0 and not bad_log.exists(), 'Invalid flag must fail before changing UFW'
    result = subprocess.run(['bash', '-c', 'source "$1"; configure_openvpn_wss "$2"', 'test',
        entrypoint, str(base / 'invalid-wrapper')], env={**environment, 'OPENVPN_WSS_ONLY': 'typo'}, text=True, capture_output=True)
    assert result.returncode != 0
    print('PASS: invalid flags fail closed before firewall or OpenVPN changes')
PY
