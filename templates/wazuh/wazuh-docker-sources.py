#!/usr/bin/env python3
"""Attach Docker names and Compose labels at collection time; refresh after container changes."""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET


def inventory():
    ids = subprocess.check_output(['docker', 'ps', '-aq'], text=True, timeout=20).split()
    if not ids:
        return []
    containers = json.loads(subprocess.check_output(['docker', 'inspect', *ids], text=True, timeout=30))
    # Environment variables and other container secrets are never serialized or logged.
    result = []
    spool_root = None
    for c in containers:
        driver = c.get('HostConfig', {}).get('LogConfig', {}).get('Type')
        if driver not in ['json-file', 'local', 'journald']:
            continue
        bridge = driver != 'json-file'
        if bridge and spool_root is None:
            docker_root = subprocess.check_output(['docker', 'info', '--format', '{{.DockerRootDir}}'], text=True, timeout=20).strip()
            spool_root = pathlib.Path(docker_root).parent / 'wazuh-docker-logs'
        path = str(spool_root / (c['Id'] + '.json.log')) if bridge else c.get('LogPath')
        if path:
            result.append({'id': c['Id'], 'name': c.get('Name', '').lstrip('/'), 'path': path,
                           'labels': c.get('Config', {}).get('Labels') or {},
                           'bridge': bridge, 'created': c.get('Created')})
    return result


def sync_bridges(containers, initial, state_path=None):
    """Read Docker's binary local driver through its API without restarting application containers."""
    bridges = [c for c in containers if c.get('bridge')]
    if not bridges:
        return
    state_path = state_path or pathlib.Path('/var/ossec/etc/datagate-docker-bridge.json')
    first_bridge_rollout = not state_path.exists()
    state = json.loads(state_path.read_text()) if state_path.exists() else {}
    now = datetime.datetime.now(datetime.timezone.utc)
    end = now.isoformat().replace('+00:00', 'Z')
    for c in bridges:
        cursor = state.get(c['id'], {})
        created = c.get('created') or end
        age = (now - datetime.datetime.fromisoformat(created.replace('Z', '+00:00'))).total_seconds()
        baseline = end if initial or (first_bridge_rollout and age > 300) else created
        since = cursor.get('until') or baseline
        since = (datetime.datetime.fromisoformat(since.replace('Z', '+00:00')) - datetime.timedelta(seconds=2)).isoformat()
        result = subprocess.run(['docker', 'logs', '--timestamps', '--since', since, '--until', end, c['id']],
                                text=True, errors='replace', capture_output=True, timeout=25)
        if result.returncode:
            raise RuntimeError('Could not read Docker logs for ' + c['name'])
        seen = set(cursor.get('seen', []))
        recent = []
        records = []
        for stream, text in [('stdout', result.stdout), ('stderr', result.stderr)]:
            timestamp = end
            for line in text.splitlines():
                parts = line.split(' ', 1)
                if len(parts) == 2 and len(parts[0]) > 19 and parts[0][4:5] == '-' and 'T' in parts[0]:
                    timestamp, line = parts
                digest = hashlib.sha256((timestamp + stream + line).encode()).hexdigest()
                if digest in seen:
                    recent.append(digest)
                    continue
                seen.add(digest)
                recent.append(digest)
                records.append(json.dumps({'log': line + '\n', 'time': timestamp, 'stream': stream}) + '\n')
        path = pathlib.Path(c['path'])
        path.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
        if path.exists() and path.stat().st_size > 10 * 1024 * 1024:
            path.with_suffix(path.suffix + '.2').unlink(missing_ok=True)
            previous = path.with_suffix(path.suffix + '.1')
            if previous.exists(): previous.rename(path.with_suffix(path.suffix + '.2'))
            path.rename(previous)
        with path.open('a') as out:
            out.writelines(records)
        os.chmod(path, 0o640)
        state[c['id']] = {'until': end, 'seen': recent[-20000:]}
    state_path.write_text(json.dumps(state))
    os.chmod(state_path, 0o600)


def sources(containers, previous, initial):
    result = []
    for c in sorted(containers, key=lambda c: c['path']):
        node = ET.Element('localfile')
        ET.SubElement(node, 'log_format').text = 'json'
        ET.SubElement(node, 'location').text = c['path']
        # Existing logs are not replayed on first rollout. New containers include their startup records.
        ET.SubElement(node, 'only-future-events').text = previous.get(c['path'], 'yes' if initial else 'no')
        labels = {'datagate.managed_docker': 'yes', 'docker.container.id': c['id'],
                  'docker.container.name': c['name'],
                  'attrs.com.docker.compose.project': c['labels'].get('com.docker.compose.project', 'standalone'),
                  'attrs.com.docker.compose.service': c['labels'].get('com.docker.compose.service', c['name'])}
        for key, value in labels.items():
            ET.SubElement(node, 'label', {'key': key}).text = value
        result.append(node)
    return result


def fingerprint(nodes):
    return [(n.findtext('location'), n.findtext('only-future-events', 'yes'),
             sorted((label.get('key'), label.text) for label in n.findall('label'))) for n in nodes]


def refresh(config, restart=True):
    original = config.read_bytes()
    root = ET.fromstring('<root>' + original.decode() + '</root>')
    main = root.find('ossec_config')
    if main is None:
        raise RuntimeError('ossec_config is missing')
    old = [(section, n) for section in root for n in section.findall('localfile')
           if n.findtext('log_format') == 'json' and ('/containers/' in n.findtext('location', '')
               or any(x.get('key') == 'datagate.managed_docker' for x in n.findall('label')))]
    managed = [n for _, n in old if any(x.get('key') == 'datagate.managed_docker' for x in n.findall('label'))]
    state = config.with_name('datagate-docker-sources.initialized')
    containers = inventory()
    sync_bridges(containers, not state.exists())
    previous = {n.findtext('location'): n.findtext('only-future-events', 'yes') for n in managed}
    previous_ids = {next((x.text for x in n.findall('label') if x.get('key') == 'docker.container.id'), ''):
                    n.findtext('only-future-events', 'yes') for n in managed}
    for c in containers:
        if c['id'] in previous_ids:
            previous.setdefault(c['path'], previous_ids[c['id']])
    desired = sources(containers, previous, not state.exists())
    if fingerprint([n for _, n in old]) == fingerprint(desired):
        state.touch(exist_ok=True)
        return False
    for section, node in old:
        section.remove(node)
    main.extend(desired)
    ET.indent(root, space='  ')
    text = '\n'.join(ET.tostring(c, encoding='unicode').rstrip() for c in root) + '\n'
    backup = config.with_name('ossec.conf.before-docker-labels')
    shutil.copy2(config, backup)
    fd, tmp = tempfile.mkstemp(dir=config.parent, prefix='.docker-sources-')
    try:
        stat = config.stat()
        with os.fdopen(fd, 'w') as out:
            out.write(text)
        os.chmod(tmp, stat.st_mode & 0o777)
        os.chown(tmp, stat.st_uid, stat.st_gid)
        os.replace(tmp, config)
        check = subprocess.run(['/var/ossec/bin/wazuh-logcollector', '-t'], capture_output=True, timeout=30)
        if check.returncode:
            shutil.copy2(backup, config)
            raise RuntimeError('Wazuh rejected Docker source configuration; backup restored')
        state.touch(exist_ok=True)
        if restart:
            subprocess.run(['systemctl', 'restart', 'wazuh-agent'], check=True, timeout=90)
    finally:
        pathlib.Path(tmp).unlink(missing_ok=True)
    print(json.dumps({'docker_sources_updated': len(desired)}))
    return True


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--no-restart', action='store_true')
    args = parser.parse_args()
    # Docker may be installed after Wazuh on a newly provisioned database/dashboard host.
    if shutil.which('docker') and pathlib.Path('/var/ossec/etc/ossec.conf').exists():
        with open('/var/ossec/var/run/datagate-docker-sources.lock', 'w') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            refresh(pathlib.Path('/var/ossec/etc/ossec.conf'), restart=not args.no_restart)
    elif pathlib.Path('/var/ossec/etc/ossec.conf').exists():
        pathlib.Path('/var/ossec/etc/datagate-docker-sources.initialized').touch(exist_ok=True)
