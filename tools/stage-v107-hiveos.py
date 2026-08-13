import hashlib
import os
import shutil
from pathlib import Path

version = '1.0.7'
root_name = f'PepeW-Miner-v{version}'
build_dir = Path(os.environ.get('PEPEW_BUILD_DIR', 'build-v107-v100'))
stage_root = Path(os.environ.get('PEPEW_STAGE_ROOT', 'dist-stage'))
package = stage_root / root_name
source_commit = os.environ.get('GITHUB_SHA', 'unknown')

if package.exists():
    shutil.rmtree(package)
package.mkdir(parents=True, exist_ok=True)

files = {
    build_dir / 'pepepowminer': ('pepepowminer', 0o755),
    Path('hiveos/h-config.sh'): ('h-config.sh', 0o755),
    Path('hiveos/h-run.sh'): ('h-run.sh', 0o755),
    Path('hiveos/h-stats.sh'): ('h-stats.sh', 0o755),
    Path('hiveos/console-monitor.sh'): ('console-monitor.sh', 0o755),
    Path('hiveos/stratum-replay-proxy.py'): ('stratum-replay-proxy.py', 0o755),
    Path('hiveos/h-manifest.conf'): ('h-manifest.conf', 0o644),
    Path('LICENSE'): ('LICENSE', 0o644),
    Path('README.md'): ('README.md', 0o644),
}
for src, (name, mode) in files.items():
    if not src.exists():
        raise SystemExit(f'missing package input: {src}')
    dst = package / name
    shutil.copy2(src, dst)
    dst.chmod(mode)

run = package / 'h-run.sh'
s = run.read_text(encoding='utf-8')
s = s.replace("    70) printf 'volta-auto' ;;", "    70) printf 'volta-async3' ;;")
s = s.replace("    70|120) printf '512' ;;", "    70) printf '768' ;;\n    120) printf '512' ;;")
s = s.replace('v1.0.5', 'v1.0.7')
s = s.replace('PEPEW_V105_WRAPPER_GATE', 'PEPEW_V107_WRAPPER_GATE')
run.write_text(s, encoding='utf-8')
run.chmod(0o755)

cfg = package / 'h-config.sh'
s = cfg.read_text(encoding='utf-8')
s = s.replace('v1.0.5', 'v1.0.7').replace('1.0.5', '1.0.7')
cfg.write_text(s, encoding='utf-8')
cfg.chmod(0o755)

manifest_path = package / 'h-manifest.conf'
manifest = manifest_path.read_text(encoding='utf-8')
expected_name = 'CUSTOM_NAME=PepeW-Miner-v1.0.7'
expected_version = 'CUSTOM_VERSION=1.0.7'
expected_config = 'CUSTOM_CONFIG_FILENAME=/hive/miners/custom/PepeW-Miner-v1.0.7/config.txt'
if expected_name not in manifest or expected_version not in manifest or expected_config not in manifest:
    raise SystemExit('v1.0.7 HiveOS manifest/root verification failed')
if 'PepeW-Miner-v1.0.7-HiveOS' in manifest:
    raise SystemExit('legacy -HiveOS directory suffix must not appear in v1.0.7 manifest')
if "70) printf 'volta-async3'" not in run.read_text(encoding='utf-8'):
    raise SystemExit('volta-async3 profile patch failed')
if "70) printf '768'" not in run.read_text(encoding='utf-8'):
    raise SystemExit('V100 thread patch failed')

(package / 'VERSION').write_text(version + '\n', encoding='utf-8')
binary = package / 'pepepowminer'
digest = hashlib.sha256(binary.read_bytes()).hexdigest()
(package / 'pepepowminer.sha256').write_text(f'{digest}  pepepowminer\n', encoding='utf-8')
(package / 'BUILD_PROFILE').write_text(
    '\n'.join([
        'release=PepeW Miner v1.0.7 V100 async3',
        f'source_commit={source_commit}',
        'build_type=Release',
        'cuda_toolkit=12.8.1',
        'cuda_architectures=70-real',
        'cuda_native=sm_70',
        'kernel_mode=volta-async3',
        'service_warps=3',
        'worker_warps=21',
        'service_threads=96',
        'worker_threads=672',
        'hot_loop_block_barriers=0',
        'launch_barriers=1',
        'mailbox=per-worker-shared-memory',
        'chunk_size=262144',
        'fmad=false',
        'cpu_candidate_validation=consensus-exact',
        'hiveos_package_root=PepeW-Miner-v1.0.7',
        'hiveos_custom_name=PepeW-Miner-v1.0.7',
        f'binary_sha256={digest}',
        ''
    ]), encoding='utf-8')
print(f'PACKAGE_DIR={package}')
print(f'HIVEOS_ROOT={root_name}')
print(f'BINARY_SHA256={digest}')
