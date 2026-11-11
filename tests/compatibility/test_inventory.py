import importlib.util
import unittest
from pathlib import Path

path = Path(__file__).resolve().parents[2] / 'scripts' / 'plugin-compatibility-inventory.py'
spec = importlib.util.spec_from_file_location('inventory', path)
inventory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inventory)


class InventoryTests(unittest.TestCase):
    def setUp(self):
        self.entry = {'name': 'fixture', 'url': 'https://and7ey.github.io/test.js',
                      'category': 'settings', 'registry': 'fixture'}

    def test_static_mentions_are_not_runtime_evidence(self):
        report = inventory.inspect(self.entry, lambda _: (b'Lampa.SettingsApi.addParam({}); $(x).html(y)', 'application/javascript'))
        self.assertEqual(report['classification'], 'NOT_TESTED')
        self.assertEqual(report['static_api_mentions'], ['SettingsApi'])
        self.assertEqual(report['observed_api_dependencies'], [])
        self.assertEqual(report['behavioral_checks'], [])
        self.assertEqual(len(report['sha256']), 64)

    def test_html_is_not_a_script(self):
        report = inventory.inspect(self.entry, lambda _: (b'<!doctype html><html>', 'text/html'))
        self.assertTrue(report['download'].startswith('failed:'))
        self.assertEqual(report['classification'], 'NOT_TESTED')

    def test_failure_is_not_a_runtime_load_failure(self):
        def fail(_):
            raise ValueError('offline')
        report = inventory.inspect(self.entry, fail)
        self.assertEqual(report['download'], 'failed: offline')
        self.assertEqual(report['classification'], 'NOT_TESTED')

    def test_unapproved_url_is_rejected_before_network(self):
        for url in ('http://and7ey.github.io/x', 'https://localhost/x',
                    'https://user@and7ey.github.io/x', 'https://and7ey.github.io:444/x'):
            with self.assertRaises(ValueError):
                inventory.download(url)


if __name__ == '__main__':
    unittest.main()
