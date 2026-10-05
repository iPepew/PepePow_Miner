import datetime
import os
import subprocess
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

if __name__ == '__main__':
    unittest.main(verbosity=2)
