"""CPU-only adapter integration: no CUDA, driver, rig or pool is contacted."""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

SOURCE = Path(__file__).resolve().parents[1]

NATIVE = '''#!/usr/bin/env python3
import json, os, pathlib, signal, sys, time
uuid = os.environ.get('CUDA_VISIBLE_DEVICES', '')
if sys.argv[1:] == ['--list-gpu']:
    print('PepeW Miner v1.0.5')
    if uuid == 'GPU-rtx2': print('[0] NVIDIA GeForce RTX 3080 sm_86')
    elif uuid == 'GPU-rtx': print('[0] NVIDIA GeForce RTX 3080 sm_86')
    else: sys.exit(9)
    sys.exit(0)
if sys.argv[1:] == ['--version']: print('native-build-identity'); sys.exit(0)
if sys.argv[1:] == ['--help']: print('native-help'); sys.exit(0)
log = pathlib.Path(sys.argv[sys.argv.index('--diagnostic-log') + 1])
log.with_name('captured.json').write_text(json.dumps({'argv':sys.argv[1:],
    'uuid':uuid, 'threads':os.environ.get('PEPEPOW_CUDA_THREADS_RUNTIME'),
    'binary':str(pathlib.Path(__file__).parent.name), 'pid':os.getpid()}))
signal.signal(signal.SIGTERM, lambda *args: sys.exit(0))
time.sleep(30)
'''

SMI = '''#!/usr/bin/env bash
case "$*" in
  *driver_version*) echo 580.0 ;;
  *memory.total*) printf '%s\\n' '0, GPU-rtx, NVIDIA GeForce RTX 3080, 00000000:02:00.0, 10240' '1, GPU-rtx2, NVIDIA GeForce RTX 3080, 00000000:01:00.0, 16384' ;;
  *) printf '%s\\n' '0, 50, 40, 210, 1500, 9000' '1, 55, N/A, 190, 1200, 800' ;;
esac
'''


class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='pepew test ')
        self.root = Path(self.tmp.name)
        self.package = self.root / 'pepew-miner-1.0.0-linux-x86_64'
        self.package.mkdir()
        (self.package / 'libexec').mkdir()
        for name in ('h-manifest.conf', 'h-run.sh', 'h-config.sh', 'h-stats.sh', 'pepepowminer'):
            shutil.copyfile(SOURCE / 'hiveos' / name, self.package / name)
            (self.package / name).chmod(0o755)
        shutil.copyfile(SOURCE / 'hiveos/console-monitor.sh', self.package / 'libexec/console-monitor.sh')
        (self.package / 'libexec/console-monitor.sh').chmod(0o755)
        self.write_exe('libexec/stratum-replay-proxy.py', '#!/usr/bin/env python3\nimport time\ntime.sleep(30)\n')
        for name in ('general', 'v100'):
            (self.package / 'bin' / name).mkdir(parents=True)
            self.write_exe('bin/' + name + '/pepepowminer', NATIVE)
        (self.package / 'VERSION').write_text('1.0.0\n')
        self.commands = self.root / 'commands'
        self.commands.mkdir()
        (self.commands / 'nvidia-smi').write_text(SMI)
        (self.commands / 'nvidia-smi').chmod(0o755)
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('PEPEW_', 'PEPEPOW_', 'CUSTOM_', 'CUDA_VISIBLE_DEVICES'))}
        self.env.update(PATH=str(self.commands) + ':' + os.environ['PATH'],
                        CUSTOM_URL='stratum+tcp://example.invalid:3333',
                        CUSTOM_TEMPLATE='PRIVATE_WALLET', CUSTOM_PASS='PRIVATE_PASSWORD',
                        PEPEW_LOG_ROOT=str(self.root / 'logs'))
        self.children = []

    def tearDown(self):
        for process in self.children:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=5)
        self.tmp.cleanup()

    def write_exe(self, name, data):
        p = self.package / name
        p.write_text(data)
        p.chmod(0o755)

    def run_file(self, name, *args, **env):
        return subprocess.run(['bash', str(self.package / name), *args],
                              env=dict(self.env, **env), text=True,
                              capture_output=True, timeout=20)

    def test_manifest_config_uses_installed_directory(self):
        result = subprocess.run(['bash', '-eu', '-c',
            'source "$1/h-manifest.conf"; source "$1/h-config.sh"; '
            'printf "%s\\n" "$CUSTOM_NAME" "$CUSTOM_VERSION" "$CUSTOM_CONFIG_FILENAME" "$CUSTOM_LOG_BASENAME"',
            'test', str(self.package)], env=self.env, text=True,
            capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), [self.package.name, '1.0.0',
            str(self.package / 'config.txt'), '/var/log/miner/custom/' + self.package.name + '/pepew'])
        self.assertTrue((self.package / 'config.txt').is_file())

    def test_version_without_gpu_and_invalid_profile(self):
        result = self.run_file('pepepowminer', '--version')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('1.0.0', result.stdout)
        self.assertEqual(self.run_file('pepepowminer', '--version', PEPEW_BINARY_PROFILE='../x').returncode, 64)
        result = self.run_file('pepepowminer', '--backend-version', PEPEW_BINARY_PROFILE='general')
        self.assertEqual(result.stdout.strip(), 'native-build-identity')

    def test_v100_profile_is_postponed(self):
        self.assertEqual(self.run_file('pepepowminer', '--version', PEPEW_BINARY_PROFILE='v100').returncode, 64)

    def test_uuid_mapping_for_two_rtx_cards(self):
        result = self.run_file('h-run.sh', PEPEW_WRAPPER_SELFTEST='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('GPU 0 | NVIDIA GeForce RTX 3080 | sm_86', result.stdout)
        self.assertIn('profile=ampere-auto | threads=768', result.stdout)
        self.assertEqual(result.stdout.count('profile=ampere-auto | threads=768'), 2)
        self.assertNotIn('PRIVATE_', result.stdout + result.stderr)

    def test_v100_device_and_inherited_visibility_rejected(self):
        (self.commands / 'nvidia-smi').write_text(SMI.replace('NVIDIA GeForce RTX 3080', 'Tesla V100'))
        result = self.run_file('h-run.sh', PEPEW_WRAPPER_SELFTEST='1')
        self.assertEqual(result.returncode, 64)
        self.assertIn('postponed', result.stderr)
        result = self.run_file('h-run.sh', PEPEW_WRAPPER_SELFTEST='1', CUDA_VISIBLE_DEVICES='GPU-rtx')
        self.assertEqual(result.returncode, 78)

    def test_multiple_cuda_devices_rejected(self):
        self.write_exe('bin/general/pepepowminer', '#!/bin/sh\nprintf "[0] V100 sm_70\\n[1] V100 sm_70\\n"\n')
        result = self.run_file('h-run.sh', PEPEW_WRAPPER_SELFTEST='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('exactly one', result.stderr)

    def test_mixed_worker_launch_arguments_and_termination(self):
        out = self.root / 'wrapper.log'
        with out.open('w') as stream:
            process = subprocess.Popen(['bash', str(self.package / 'h-run.sh')],
                env=self.env, stdout=stream,
                stderr=subprocess.STDOUT, start_new_session=True)
            self.children.append(process)
            deadline = time.monotonic() + 10
            captures = [self.package / f'gpu{i}/captured.json' for i in (0, 1)]
            while time.monotonic() < deadline and not all(p.exists() for p in captures):
                if process.poll() is not None: break
                time.sleep(0.1)
            self.assertTrue(all(p.exists() for p in captures), out.read_text())
            data = [json.loads(p.read_text()) for p in captures]
            self.assertEqual([(v['uuid'], v['binary'], v['threads']) for v in data],
                             [('GPU-rtx', 'general', '768'), ('GPU-rtx2', 'general', '768')])
            for v in data:
                self.assertEqual(v['argv'][v['argv'].index('-u') + 1], 'PRIVATE_WALLET')
                self.assertEqual(v['argv'][v['argv'].index('-p') + 1], 'PRIVATE_PASSWORD')
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=10), 0, out.read_text())
            for v in data:
                with self.assertRaises(ProcessLookupError): os.kill(v['pid'], 0)
            self.assertFalse(any(self.package.glob('gpu*/*.pid')))
            self.assertFalse(any(self.package.glob('.console-events.*.fifo')))
            self.assertNotIn('PRIVATE_', out.read_text())
            self.assertNotIn('BUILD_PROFILE: No such file or directory', out.read_text())

    def test_worker_error_propagates_and_stops_other_worker(self):
        self.write_exe('bin/general/pepepowminer', NATIVE.replace(
            'time.sleep(30)', 'time.sleep(1); sys.exit(23)'))
        with (self.root / 'failure.log').open('w') as output:
            process = subprocess.Popen(['bash', str(self.package / 'h-run.sh')],
                env=self.env, stdout=output,
                stderr=subprocess.STDOUT, start_new_session=True)
            self.children.append(process)
            self.assertEqual(process.wait(timeout=12), 23)
        self.assertIn('reason=gpu0_miner_exit', (self.root / 'logs/miner-exit-status.txt').read_text())
        other = json.loads((self.package / 'gpu1/captured.json').read_text())
        with self.assertRaises(ProcessLookupError): os.kill(other['pid'], 0)
        self.assertFalse(any(self.package.glob('gpu*/*.pid')))

    def test_stats_with_mocked_executable_path_rejects_old_log(self):
        executable = self.package / 'bin/general/pepepowminer'
        shutil.copyfile(shutil.which('sleep'), executable)
        process = subprocess.Popen([str(executable), '20'], start_new_session=True)
        self.children.append(process)
        # This host denies /proc/<pid>/exe reads. Model the readlink result;
        # never retry or work around that access restriction. Target-host PID
        # identity validation remains an explicit hardware integration gate.
        readlink = self.commands / 'readlink'
        readlink.write_text('#!/bin/sh\nprintf "%s\\n" "$PEPEW_TEST_EXE"\n')
        readlink.chmod(0o755)
        (self.package / 'active-workers.env').write_text('GPU_LIST=0\n')
        directory = self.package / 'gpu0'
        directory.mkdir()
        (directory / 'miner.pid').write_text(str(process.pid))
        now = int(time.time())
        (directory / 'miner-status.env').write_text(f'HPS=3000000\nUPDATED_EPOCH={now}\nPID={process.pid}\n')
        log = self.root / 'logs/gpu0/pepew.log'
        log.parent.mkdir(parents=True)
        log.write_text('[MINING] 9.999 MH/s\n')
        os.utime(log, (now - 100, now - 100))
        rows = self.root / 'nvidia.csv'
        rows.write_text('0, 00000000:02:00.0, 50, 40, 210\n')
        def read_stats():
            result = subprocess.run(['bash', '-c', 'source "$1"; printf "%s" "$stats"',
                                     'bash', str(self.package / 'h-stats.sh')],
                env=dict(self.env, PEPEW_NVIDIA_SMI_FILE=str(rows), PEPEW_TEST_EXE=str(executable)),
                capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertEqual(read_stats()['hs'], [3000])
        (directory / 'miner-status.env').write_text('HPS=3000000\nUPDATED_EPOCH=1\n')
        self.assertEqual(read_stats()['hs'], [0])

    def test_stats_selected_order_unknown_sensors_and_version(self):
        (self.package / 'active-workers.env').write_text('GPU_LIST=1,0\n')
        for i, hps in ((0, 3500000), (1, 11492000)):
            directory = self.package / f'gpu{i}'
            directory.mkdir()
            (directory / 'miner-status.env').write_text(f'HPS={hps}\nACCEPTED=2\nREJECTED=0\nUPTIME=10\n')
        rows = self.root / 'nvidia.csv'
        rows.write_text('1, 00000000:01:00.0, 55, N/A, 190.5\n0, 00000000:02:00.0, 50, 40, 210\n2, 00000000:03:00.0, 60, 50, 220\n')
        result = subprocess.run(['bash', '-c', 'source "$1"; printf "%s" "$stats"',
                                 'bash', str(self.package / 'h-stats.sh')],
            env=dict(self.env, PEPEW_STATS_SELFTEST='1', PEPEW_NVIDIA_SMI_FILE=str(rows)),
            capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        stats = json.loads(result.stdout)
        self.assertEqual(stats['hs'], [11492, 3500])
        self.assertEqual(stats['bus_numbers'], [1, 2])
        self.assertEqual(stats['fan'], [None, 40])
        self.assertEqual(stats['power'], [190.5, 210])
        self.assertEqual(stats['ar'], [4, 0, 0])
        self.assertEqual(stats['ver'], '1.0.0')


if __name__ == '__main__':
    unittest.main()
