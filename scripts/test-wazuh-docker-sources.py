#!/usr/bin/env python3
import pathlib
import datetime
import json
import runpy
import tempfile
import types
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

MODULE = runpy.run_path(str(pathlib.Path(__file__).resolve().parents[1] / 'templates/wazuh/wazuh-docker-sources.py'))
CONTAINER = {'id': 'a' * 64, 'name': 'datagate-backend', 'path': '/var/lib/docker/containers/a/a-json.log',
             'labels': {'com.docker.compose.project': 'datagate', 'com.docker.compose.service': 'backend'}}


class DockerSourcesTests(unittest.TestCase):
    def test_binary_driver_bridge_avoids_history_and_deduplicates_overlap(self):
        with tempfile.TemporaryDirectory() as folder:
            now = datetime.datetime.now(datetime.timezone.utc)
            stamp = now.isoformat().replace('+00:00', 'Z')
            old = (now - datetime.timedelta(days=2)).isoformat().replace('+00:00', 'Z')
            container = {**CONTAINER, 'bridge': True, 'created': old, 'path': str(pathlib.Path(folder) / 'logs/c.json.log')}
            state = pathlib.Path(folder) / 'cursor.json'
            response = types.SimpleNamespace(returncode=0, stdout=stamp + ' hello\n', stderr='')
            with mock.patch('subprocess.run', return_value=response) as command:
                MODULE['sync_bridges']([container], False, state)
                requested_since = command.call_args.args[0][4]
                self.assertGreater(datetime.datetime.fromisoformat(requested_since), now - datetime.timedelta(seconds=10))
                MODULE['sync_bridges']([container], False, state)
            lines = pathlib.Path(container['path']).read_text().splitlines()
            self.assertEqual(1, len(lines))
            self.assertEqual('hello\n', json.loads(lines[0])['log'])

    def test_native_labels_and_first_rollout_do_not_replay_history(self):
        node = MODULE['sources']([CONTAINER], {}, True)[0]
        labels = {n.get('key'): n.text for n in node.findall('label')}
        self.assertEqual('backend', labels['attrs.com.docker.compose.service'])
        self.assertEqual('datagate', labels['attrs.com.docker.compose.project'])
        self.assertEqual('yes', node.findtext('only-future-events'))

    def test_new_containers_include_startup_logs_and_existing_offsets_are_preserved(self):
        self.assertEqual('no', MODULE['sources']([CONTAINER], {}, False)[0].findtext('only-future-events'))
        self.assertEqual('yes', MODULE['sources']([CONTAINER], {CONTAINER['path']: 'yes'}, False)[0].findtext('only-future-events'))

    def test_refresh_preserves_system_sources_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as folder:
            config = pathlib.Path(folder) / 'ossec.conf'
            config.write_text('<ossec_config><client/><localfile><log_format>journald</log_format><location>journald</location></localfile><localfile><log_format>json</log_format><location>/var/lib/docker/containers/*/*.log</location></localfile></ossec_config>')
            globals_ = MODULE['refresh'].__globals__
            with mock.patch.dict(globals_, {'inventory': lambda: [CONTAINER]}), mock.patch('subprocess.run', return_value=types.SimpleNamespace(returncode=0)) as command:
                self.assertTrue(MODULE['refresh'](config, restart=False))
                self.assertFalse(MODULE['refresh'](config, restart=False))
                self.assertEqual(1, command.call_count)
            root = ET.fromstring('<root>' + config.read_text() + '</root>')
            self.assertIn('journald', [n.text for n in root.findall('.//localfile/location')])
            self.assertEqual(1, len(root.findall('.//localfile[label]')))

    def test_invalid_configuration_restores_previous_file(self):
        with tempfile.TemporaryDirectory() as folder:
            config = pathlib.Path(folder) / 'ossec.conf'
            original = '<ossec_config><client/></ossec_config>'
            config.write_text(original)
            with mock.patch.dict(MODULE['refresh'].__globals__, {'inventory': lambda: [CONTAINER]}), mock.patch('subprocess.run', return_value=types.SimpleNamespace(returncode=1)):
                with self.assertRaises(RuntimeError):
                    MODULE['refresh'](config, restart=False)
            self.assertEqual(original, config.read_text())


if __name__ == '__main__':
    unittest.main()
