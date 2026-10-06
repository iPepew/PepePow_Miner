import datetime
import os
import hashlib
import json
import subprocess
import tarfile
import tempfile
import unittest
from pathlib import Path
import yaml

WORKFLOW = Path(os.environ.get('PEPEW_GATE_FILE', str(Path(__file__).resolve().parents[1] / '.github/workflows/current-source-v100-package-gate-20261005.yml')))
DOC = yaml.load(WORKFLOW.read_text(), Loader=yaml.BaseLoader)
STEPS = DOC['jobs']['package']['steps']

class GateTests(unittest.TestCase):
    def test_shell_syntax(self):
        for step in STEPS:
            if 'run' in step:
                with self.subTest(step=step['name']):
                    subprocess.run(['bash', '-n'], input=step['run'], text=True, check=True, timeout=3)

    def test_deadline_guard(self):
        now = datetime.datetime.now(datetime.timezone.utc)
        fmt = lambda seconds: (now + datetime.timedelta(seconds=seconds)).strftime('%Y-%m-%dT%H:%M:%SZ')
        cases = [('', False), ('invalid', False), (fmt(-60), False),
                 (fmt(60), False), (fmt(1200), False), (fmt(2400), True), (fmt(7200), False)]
        for deadline, allowed in cases:
            with self.subTest(deadline=deadline):
                env = dict(os.environ, SESSION_DEADLINE_UTC=deadline)
                result = subprocess.run(['bash', '-c', STEPS[0]['run']], env=env,
                                        capture_output=True, text=True, timeout=3)
                self.assertEqual(result.returncode == 0, allowed)

    def test_pinned_checkout_and_order(self):
        names = [s.get('name', '') for s in STEPS]
        self.assertLess(names.index('Install bounded build tools'), names.index('Checkout immutable production source'))
        checkouts = [s for s in STEPS if s.get('uses', '').startswith('actions/checkout@')]
        self.assertEqual(len(checkouts), 1)
        self.assertEqual(checkouts[0]['with']['ref'], '${{ env.EXPECTED_SOURCE }}')
        self.assertEqual(checkouts[0]['with']['persist-credentials'], 'false')
        self.assertNotIn('merge-base', WORKFLOW.read_text())
        self.assertIn('git config --global --add safe.directory "$GITHUB_WORKSPACE"', WORKFLOW.read_text())

    def test_no_auto_trigger_or_gpu_execution(self):
        self.assertEqual(set(DOC['on']), {'workflow_dispatch'})
        self.assertEqual(DOC['permissions'], {'contents': 'read'})
        self.assertEqual(DOC['jobs']['package']['timeout-minutes'], '18')
        self.assertNotIn('./build/pepepow_header80_differential', WORKFLOW.read_text())
        self.assertNotIn('gh release', WORKFLOW.read_text())

    def test_failure_diagnostics(self):
        upload = [s for s in STEPS if s.get('uses', '').startswith('actions/upload-artifact@')][0]
        self.assertEqual(upload['if'], '${{ always() && !cancelled() }}')

class PackageTests(unittest.TestCase):
    targets = ('pepepow_cuda_tests', 'pepepow_cuda_header80_validation',
               'pepepow_header80_benchmark', 'pepepow_header80_differential')

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        for directory in ('build', 'hiveos', 'logs'):
            (self.root / directory).mkdir()
        # Deliberately non-executable contents: packaging must never run CUDA tools.
        for name in ('pepepowminer',) + self.targets:
            (self.root / 'build' / name).write_text('fixture binary ' + name + '\n')
        for name in ('h-config.sh', 'h-run.sh', 'h-stats.sh', 'stratum-replay-proxy.py', 'h-manifest.conf'):
            (self.root / 'hiveos' / name).write_text('fixture ' + name + '\n')
        (self.root / 'logs/resources.json').write_text('{"identity_pass": true}\n')
        (self.root / 'logs/source.env').write_text('source_commit=fixture\n')
        self.env = dict(os.environ, ROOT='PepeW-Miner', ASSET='fixture.tar.gz',
                        EXPECTED_SOURCE='1' * 40, GITHUB_SHA='2' * 40)
        self.script = next(s['run'] for s in STEPS
                           if s.get('name') == 'Assemble deterministic verification package')
        self.script = self.script.replace('/tmp/resources.json', str(self.root / 'logs/resources.json'))
        self.script = self.script.replace('/tmp/source.env', str(self.root / 'logs/source.env'))

    def assemble(self):
        return subprocess.run(['bash', '-c', self.script], cwd=self.root, env=self.env,
                              capture_output=True, text=True, timeout=10)

    def test_complete_manifest_and_deterministic_archive(self):
        result = self.assemble()
        self.assertEqual(result.returncode, 0, result.stderr)
        package = self.root / 'dist/fixture.tar.gz'
        first = package.read_bytes()
        stage = self.root / 'stage/PepeW-Miner'
        sums = dict(line.split('  ', 1)[::-1] for line in (stage / 'SHA256SUMS').read_text().splitlines())
        files = {'./' + str(p.relative_to(stage)) for p in stage.rglob('*')
                 if p.is_file() and p.name != 'SHA256SUMS'}
        self.assertEqual(set(sums), files)
        for path, digest in sums.items():
            self.assertEqual(hashlib.sha256((stage / path).read_bytes()).hexdigest(), digest)
        report = json.loads((self.root / 'dist/result.json').read_text())
        self.assertEqual(set(report['verification_binaries']), set(self.targets))
        for name, digest in report['verification_binaries'].items():
            self.assertEqual(digest, sums['./verification/' + name])
        self.assertFalse(report['cuda_executed'])
        self.assertFalse(report['promotion_eligible'])
        with tarfile.open(package) as archive:
            for name in self.targets:
                member = archive.getmember('PepeW-Miner/verification/' + name)
                self.assertEqual(member.mode, 0o755)
        self.assertEqual(self.assemble().returncode, 0)
        self.assertEqual(first, package.read_bytes())

    def test_missing_verification_binary_fails_before_archive(self):
        (self.root / 'build' / self.targets[-1]).unlink()
        self.assertNotEqual(self.assemble().returncode, 0)
        self.assertFalse((self.root / 'dist/fixture.tar.gz').exists())

    def test_manifest_rejects_changed_verification_binary(self):
        self.assertEqual(self.assemble().returncode, 0)
        stage = self.root / 'stage/PepeW-Miner'
        (stage / 'verification' / self.targets[0]).write_text('corrupted\n')
        result = subprocess.run(['sha256sum', '-c', 'SHA256SUMS'], cwd=stage,
                                capture_output=True, text=True, timeout=3)
        self.assertNotEqual(result.returncode, 0)

if __name__ == '__main__':
    unittest.main(verbosity=2)
