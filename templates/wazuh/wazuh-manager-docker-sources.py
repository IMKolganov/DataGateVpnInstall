#!/usr/bin/env python3
"""Refresh local manager Docker sources when monitoring containers are recreated."""
import fcntl
import json
import pathlib
import subprocess

MANAGER = 'single-node-wazuh.manager-1'


def main():
    info = json.loads(subprocess.check_output(['docker', 'inspect', MANAGER], text=True, timeout=20))[0]
    if not info['State']['Running']:
        return
    ready = subprocess.run(['docker', 'exec', MANAGER, 'pgrep', 'wazuh-analysisd'], capture_output=True, timeout=15)
    if ready.returncode:
        return
    ids = subprocess.check_output(['docker', 'ps', '-aq'], text=True, timeout=20).split()
    raw = json.loads(subprocess.check_output(['docker', 'inspect', *ids], text=True, timeout=30))
    containers = [{'id': c['Id'], 'name': c.get('Name', '').lstrip('/'),
                   'path': '/var/lib/docker/containers/' + c['Id'] + '/' + c['Id'] + '-json.log',
                   'labels': {k: v for k, v in (c.get('Config', {}).get('Labels') or {}).items()
                              if k in ['com.docker.compose.project', 'com.docker.compose.service']}}
                  for c in raw if c.get('HostConfig', {}).get('LogConfig', {}).get('Type') == 'json-file'
                  and c.get('LogPath')]
    source = pathlib.Path('/usr/local/lib/datagate/wazuh-docker-sources.py').read_text()
    code = "import pathlib,shutil,json\nnamespace={'__name__':'datagate_metadata'}\n"
    code += 'exec(compile(' + repr(source) + ",'metadata-helper','exec'),namespace)\n"
    code += 'containers=' + repr(containers) + '\n'
    code += "namespace['refresh'].__globals__['inventory']=lambda:containers\n"
    code += "changed=namespace['refresh'](pathlib.Path('/var/ossec/etc/ossec.conf'),restart=False)\n"
    code += "if changed:shutil.copyfile('/var/ossec/etc/ossec.conf','/wazuh-config-mount/etc/ossec.conf')\n"
    code += "print(json.dumps({'changed':changed}))\n"
    result = subprocess.run(['docker', 'exec', '-i', MANAGER, '/var/ossec/framework/python/bin/python3', '-'],
                            input=code, text=True, capture_output=True, timeout=70)
    if result.returncode:
        raise RuntimeError('Manager Docker source refresh failed validation')
    changed = json.loads(result.stdout.splitlines()[-1])['changed']
    if changed:
        subprocess.run(['docker', 'exec', MANAGER, '/var/ossec/bin/wazuh-control', 'restart'],
                       check=True, stdout=subprocess.DEVNULL, timeout=120)
        print('Wazuh manager sources refreshed after Docker container changes')


if __name__ == '__main__':
    with open('/run/lock/datagate-wazuh-manager-docker.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        main()
