#!/usr/bin/env python3
"""Wazuh integration. Filtering is controlled by ossec.conf, without hidden rule exclusions."""
import datetime
import json
import pathlib
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

CONFIG = pathlib.Path('/var/ossec/etc/datagate-telegram.json')
DELIVERY_LOG = pathlib.Path('/var/ossec/logs/datagate-telegram-delivery.jsonl')


def compose_label(attrs, name):
    flat = attrs.get('com.docker.compose.' + name)
    if flat:
        return flat
    value = attrs
    for key in ['com', 'docker', 'compose', name]:
        value = value.get(key, {}) if isinstance(value, dict) else {}
    return value if isinstance(value, str) else ''


def message(alert):
    rule, agent, data = (alert.get(k, {}) for k in ['rule', 'agent', 'data'])
    attrs = data.get('attrs') or {}
    project, service = (compose_label(attrs, name) for name in ['project', 'service'])
    location = str(alert.get('location', ''))
    # Only local manager events can be matched to the manager's read-only Docker mount.
    match = re.search(r'/containers/([0-9a-f]{64})/', location)
    if match and agent.get('id') == '000' and (not project or not service):
        try:
            meta = json.loads(pathlib.Path('/var/lib/docker/containers', match[1], 'config.v2.json').read_text())
            labels = meta.get('Config', {}).get('Labels') or {}
            project = project or compose_label(labels, 'project')
            service = service or compose_label(labels, 'service') or meta.get('Name', '').lstrip('/')
        except (OSError, ValueError, TypeError):
            pass
    log = str(data.get('log') or alert.get('full_log') or '').strip()
    return (
        f"🚨 Wazuh alert\nLevel: {rule.get('level')}\n"
        f"Rule: {rule.get('id')} - {str(rule.get('description', ''))[:300]}\n"
        f"Agent: {agent.get('name')}\nProject: {project or 'unknown'}\n"
        f"Service: {service or 'unknown'}\nLocation: {location[:300]}\n\nLog:\n{log[:1800]}"
    )[:3900]


def record(alert, status, **extra):
    item = {'time': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'alert_id': alert.get('id'), 'agent': alert.get('agent', {}).get('name'),
            'rule_id': alert.get('rule', {}).get('id'), 'status': status, **extra}
    try:
        with DELIVERY_LOG.open('a') as out:
            out.write(json.dumps(item) + '\n')
    except OSError:
        print(json.dumps({'status': 'delivery_log_unavailable'}), file=sys.stderr)


def send(alert, config):
    payload = urllib.parse.urlencode({'chat_id': config['chat_id'], 'text': message(alert)}).encode()
    try:
        with urllib.request.urlopen(f"https://api.telegram.org/bot{config['bot_token']}/sendMessage",
                                    data=payload, timeout=10) as response:
            result = json.load(response)
        if not result.get('ok'):
            raise ValueError('Telegram did not confirm delivery')
        record(alert, 'sent', message_id=result.get('result', {}).get('message_id'))
    except urllib.error.HTTPError as error:
        record(alert, 'failed', http_status=error.code)
        raise RuntimeError(f'Telegram delivery failed: HTTP {error.code}') from None
    except Exception:
        record(alert, 'failed', reason='network-or-response-error')
        raise RuntimeError('Telegram delivery failed; see delivery log') from None


if __name__ == '__main__':
    with open(sys.argv[1], encoding='utf-8') as source:
        alert = json.load(source)
    if '--dry-run' in sys.argv[2:]:
        print(message(alert))
    else:
        send(alert, json.loads(CONFIG.read_text()))
