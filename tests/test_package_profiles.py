import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/release/package_profiles.py'
spec = importlib.util.spec_from_file_location('package_profiles', SCRIPT)
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


class PackageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        for name, sha in [('general', 'a' * 40), ('v100', 'b' * 40)]:
            folder = self.root / name
            folder.mkdir()
            hashes = {}
            for target in package.TARGETS:
                data = (name + ':' + target).encode()
                (folder / target).write_bytes(data)
                hashes[target] = hashlib.sha256(data).hexdigest()
            (folder / 'PROFILE_BUILD.json').write_text(json.dumps({
                'source_commit': sha, 'status': 'compiled-cpu-tested-gpu-unverified',
                'binary_sha256': hashes, 'secret': 'never include this'}))
            (folder / 'wallet.conf').write_text('private wallet')

    def tearDown(self):
        self.tmp.cleanup()

    def build(self, version='1.0.0-preparation.1'):
        return package.assemble(self.root / 'general', self.root / 'v100',
                                version, 'a' * 40, 'b' * 40)

    def test_deterministic(self):
        first = self.build()
        (self.root / 'general/pepepowminer').touch()
        self.assertEqual(first, self.build())

    def test_inventory_hashes_modes_and_no_secrets(self):
        with tarfile.open(fileobj=io.BytesIO(self.build()), mode='r:gz') as tar:
            members = tar.getmembers()
            self.assertEqual(len(members), 16)
            for member in members:
                self.assertTrue(member.isfile())
                self.assertTrue(member.name.startswith('pepew-miner/'))
                self.assertNotIn('..', Path(member.name).parts)
                expected_mode = 0o755 if '/bin/' in member.name or '/tests/' in member.name else 0o644
                self.assertEqual(member.mode, expected_mode)
                self.assertNotIn(b'private wallet', tar.extractfile(member).read())
                self.assertNotIn(b'never include this', tar.extractfile(member).read())
            checksums = tar.extractfile('pepew-miner/SHA256SUMS').read().decode()
            for line in checksums.splitlines():
                sha, name = line.split('  ', 1)
                self.assertEqual(sha, package.digest(tar.extractfile('pepew-miner/' + name).read()))
            manifest = json.load(tar.extractfile('pepew-miner/BUILD_MANIFEST.json'))
            self.assertFalse(manifest['installable'])

    def test_tampered_binary(self):
        (self.root / 'v100/pepepowminer').write_bytes(b'tampered')
        with self.assertRaisesRegex(ValueError, 'hash mismatch'):
            self.build()

    def test_missing_offline_binary(self):
        (self.root / 'v100/pepepow_header80_differential').unlink()
        with self.assertRaises(ValueError):
            self.build()

    def test_symlink_rejected(self):
        target = self.root / 'v100/pepepowminer'
        target.unlink()
        target.symlink_to(self.root / 'general/pepepowminer')
        with self.assertRaisesRegex(ValueError, 'symlink'):
            self.build()

    def test_wrong_source(self):
        with self.assertRaisesRegex(ValueError, 'source identity'):
            package.assemble(self.root / 'v100', self.root / 'general',
                             '1.0.0-preparation.1', 'a' * 40, 'b' * 40)

    def test_stable_version_rejected(self):
        with self.assertRaises(ValueError):
            self.build('1.0.0')


if __name__ == '__main__':
    unittest.main()
