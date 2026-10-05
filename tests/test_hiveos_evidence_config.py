"""Run only h-config.sh in a temp directory; no GPU, miner, proxy or pool."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "hiveos/h-config.sh"


class EvidenceConfigTests(unittest.TestCase):
    def configure(self, extra, previous=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = root / "h-config.sh"
            script.write_bytes(SOURCE.read_bytes())
            config = root / "config.txt"
            if previous is not None:
                config.write_bytes(previous)
            env = {
                "PATH": os.environ["PATH"], "LC_ALL": "C",
                "CUSTOM_URL": "stratum+tcp://synthetic.invalid:1234",
                "CUSTOM_TEMPLATE": "synthetic.worker", "CUSTOM_PASS": "synthetic-only",
                "CUSTOM_USER_CONFIG": extra,
            }
            run = subprocess.run(["bash", str(script)], env=env, capture_output=True,
                                 text=True, timeout=3)
            return (run, config.read_bytes() if config.exists() else None,
                    (root / "setup.txt").exists(), list(root.glob("config.txt.tmp.*")))

    def reject(self, extra):
        run, config, setup, temporary = self.configure(extra)
        self.assertEqual(run.returncode, 1)
        self.assertIn("unique file per process", run.stderr)
        self.assertIsNone(config)
        self.assertFalse(setup)
        self.assertFalse(temporary)
        self.assertNotIn("synthetic-only", run.stdout + run.stderr)

    def test_absolute_path_rejected(self):
        self.reject("--stratum-evidence /tmp/shared.jsonl")

    def test_relative_path_rejected(self):
        self.reject("--stratum-evidence shared.jsonl")

    def test_quoted_path_rejected(self):
        self.reject('--stratum-evidence "shared evidence.jsonl"')

    def test_equal_form_rejected(self):
        self.reject("--stratum-evidence=/tmp/shared.jsonl")

    def test_empty_value_rejected(self):
        self.reject('--stratum-evidence ""')

    def test_after_other_options_rejected(self):
        self.reject("--diagnostic --stratum-evidence shared.jsonl")

    def test_previous_configuration_preserved(self):
        previous = b"# previous configuration\n"
        run, config, setup, temporary = self.configure("--stratum-evidence shared.jsonl", previous)
        self.assertEqual(run.returncode, 1)
        self.assertEqual(config, previous)
        self.assertFalse(setup)
        self.assertFalse(temporary)

    def test_default_configuration_unchanged(self):
        run, config, setup, temporary = self.configure("")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn(b"PEPEPOW_EXTRA_ARGS=( )", config)
        self.assertTrue(setup)
        self.assertFalse(temporary)

    def test_diagnostic_option_preserved(self):
        run, config, _, _ = self.configure("--diagnostic")
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertIn(b"PEPEPOW_EXTRA_ARGS=( --diagnostic )", config)

    def test_existing_reserved_option_still_rejected(self):
        run, config, setup, _ = self.configure("--diagnostic-log /tmp/shared.log")
        self.assertEqual(run.returncode, 1)
        self.assertIn("Reserved option", run.stderr)
        self.assertIsNone(config)
        self.assertFalse(setup)


if __name__ == "__main__":
    unittest.main()
