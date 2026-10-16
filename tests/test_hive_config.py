import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'hiveos' / 'h-config.sh'


class HiveConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        shutil.copyfile(SOURCE, self.root / 'h-config.sh')

    def tearDown(self):
        self.tmp.cleanup()

    def configure(self, extra):
        env = {**os.environ, 'CUSTOM_URL': 'stratum+tcp://example.invalid:1234',
               'CUSTOM_TEMPLATE': 'WALLET.worker', 'CUSTOM_PASS': 'test-secret',
               'CUSTOM_CONFIG_FILENAME': str(self.root / 'config.txt'),
               'CUSTOM_USER_CONFIG': extra}
        return subprocess.run(['bash', str(self.root / 'h-config.sh')],
                              env=env, capture_output=True, text=True)

    def read_args(self):
        result = subprocess.run(['bash', '-c',
            'source "$1"; printf "%s\\0" "${PEPEPOW_EXTRA_ARGS[@]}"',
            'test', str(self.root / 'config.txt')], capture_output=True, check=True)
        return result.stdout.rstrip(b'\0').decode().split('\0')

    def test_quotes(self):
        self.assertEqual(self.configure('--label "hello world"').returncode, 0)
        self.assertEqual(self.read_args(), ['--label', 'hello world'])

    def test_substitution_is_data(self):
        marker = self.root / 'executed'
        raw = '"$(touch ' + str(marker) + ')"'
        self.assertEqual(self.configure(raw).returncode, 0)
        self.assertEqual(self.read_args(), [raw[1:-1]])
        self.assertFalse(marker.exists())

    def test_backticks_are_data(self):
        marker = self.root / 'executed'
        raw = '"`touch ' + str(marker) + '`"'
        self.assertEqual(self.configure(raw).returncode, 0)
        self.read_args()
        self.assertFalse(marker.exists())

    def test_bad_quotes(self):
        self.assertNotEqual(self.configure('--label "broken').returncode, 0)
        self.assertFalse((self.root / 'config.txt').exists())

    def test_reserved_options(self):
        for option in ['--pool=other', '-o other', '--user=other', '--profile=other']:
            with self.subTest(option=option):
                self.assertNotEqual(self.configure(option).returncode, 0)

    def test_private_config_redacted_diagnostics(self):
        self.assertEqual(self.configure('').returncode, 0)
        self.assertEqual(stat.S_IMODE((self.root / 'config.txt').stat().st_mode), 0o600)
        diagnostic = (self.root / 'setup.txt').read_text()
        self.assertNotIn('test-secret', diagnostic)
        self.assertNotIn('WALLET.worker', diagnostic)


if __name__ == '__main__':
    unittest.main()
