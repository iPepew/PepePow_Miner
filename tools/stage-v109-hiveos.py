import hashlib
import os
import shutil
from pathlib import Path

version = '1.0.9'
root_name = f'PepeW-Miner-v{version}'
build_dir = Path(os.environ.get('PEPEW_BUILD_DIR', 'build-v109-v100'))
stage_root = Path(os.environ.get('PEPEW_STAGE_ROOT', 'dist-stage'))
package = stage_root / root_name
source_commit = os.environ.get('GITHUB_SHA', 'unknown')

if package.exists():
    shutil.rmtree(package)
package.mkdir(parents=True, exist_ok=True)

files = {
    build_dir / 'pepepowminer': ('pepepowminer', 0o755),
    build_dir / 'pepepow_v100_autotune': ('pepepow-v100-autotune', 0o755),
    Path('hiveos/h-config.sh'): ('h-config.sh', 0o755),
    Path('hiveos/h-run.sh'): ('h-run.sh', 0o755),
    Path('hiveos/h-stats.sh'): ('h-stats.sh', 0o755),
    Path('hiveos/console-monitor.sh'): ('console-monitor.sh', 0o755),
    Path('hiveos/stratum-replay-proxy.py'): ('stratum-replay-proxy.py', 0o755),
    Path('hiveos/v100-autotune.sh'): ('v100-autotune.sh', 0o755),
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
s = s.replace("    70) printf 'volta-auto' ;;", "    70) printf 'volta-geometry-auto' ;;")
s = s.replace("    70|120) printf '512' ;;", "    70) printf '768' ;;\n    120) printf '512' ;;")

old_thread_select = '''    if [[ "${PEPEPOW_CUDA_THREADS_RUNTIME}" == "auto" ]]; then
      threads="$(threads_for_sm "${sm}")"
    else
      threads="${PEPEPOW_CUDA_THREADS_RUNTIME}"
    fi
'''
new_thread_select = '''    if [[ "${PEPEPOW_CUDA_THREADS_RUNTIME}" == "auto" ]]; then
      if [[ "${sm}" == "70" && -x "${miner_dir}/v100-autotune.sh" && -x "${miner_dir}/pepepow-v100-autotune" ]]; then
        threads="$("${miner_dir}/v100-autotune.sh" \
          "${miner_dir}" "${all_uuids[$position]}" "${log_dir}/gpu${index}-v100-autotune.log")"
      else
        threads="$(threads_for_sm "${sm}")"
      fi
    else
      threads="${PEPEPOW_CUDA_THREADS_RUNTIME}"
    fi
'''
if old_thread_select not in s:
    raise SystemExit('h-run thread selection marker missing')
s = s.replace(old_thread_select, new_thread_select, 1)

old_identity = 'miner_version="$(./pepepowminer --version 2>&1 | head -n1 || true)"\n'
new_identity = '''binary_identity="$(./pepepowminer --version 2>&1 | head -n1 || true)"
miner_version="v1.0.9"
'''
if old_identity not in s:
    raise SystemExit('h-run miner identity marker missing')
s = s.replace(old_identity, new_identity, 1)

old_start = "printf '%s\\n' 'PepeW Miner startup'\n"
new_start = '''printf '\\n%s\\n' 'PepeW Miner v1.0.9 - Performance & Stability Edition'
printf '%s\\n' 'PepeW - твоя монета. Твои правила.'
printf '%s\\n' '------------------------------------------------------------'
'''
if old_start not in s:
    raise SystemExit('h-run startup banner marker missing')
s = s.replace(old_start, new_start, 1)

s = s.replace('v1.0.5', 'v1.0.9')
s = s.replace('PEPEW_V105_WRAPPER_GATE', 'PEPEW_V109_WRAPPER_GATE')
s = s.replace('  echo "MINER_VERSION=${miner_version}"', '  echo "MINER_VERSION=${miner_version}"\n  echo "BINARY_IDENTITY=${binary_identity}"')
run.write_text(s, encoding='utf-8')
run.chmod(0o755)

cfg = package / 'h-config.sh'
cfg_text = cfg.read_text(encoding='utf-8')
cfg_text = cfg_text.replace('v1.0.5', 'v1.0.9').replace('1.0.5', '1.0.9')
cfg.write_text(cfg_text, encoding='utf-8')
cfg.chmod(0o755)

manifest_path = package / 'h-manifest.conf'
manifest = manifest_path.read_text(encoding='utf-8')
expected_name = 'CUSTOM_NAME=PepeW-Miner-v1.0.9'
expected_version = 'CUSTOM_VERSION=1.0.9'
expected_config = 'CUSTOM_CONFIG_FILENAME=/hive/miners/custom/PepeW-Miner-v1.0.9/config.txt'
if expected_name not in manifest or expected_version not in manifest or expected_config not in manifest:
    raise SystemExit('v1.0.9 HiveOS manifest/root verification failed')
if 'PepeW-Miner-v1.0.9-HiveOS' in manifest:
    raise SystemExit('legacy -HiveOS directory suffix must not appear in v1.0.9 manifest')
run_text = run.read_text(encoding='utf-8')
for required in (
    "70) printf 'volta-geometry-auto'",
    'v100-autotune.sh',
    'pepepow-v100-autotune',
    'PepeW Miner v1.0.9 - Performance & Stability Edition',
    'PepeW - твоя монета. Твои правила.',
):
    if required not in run_text:
        raise SystemExit(f'v1.0.9 h-run patch missing: {required}')

(package / 'VERSION').write_text(version + '\n', encoding='utf-8')
binary = package / 'pepepowminer'
digest = hashlib.sha256(binary.read_bytes()).hexdigest()
bench_digest = hashlib.sha256((package / 'pepepow-v100-autotune').read_bytes()).hexdigest()
(package / 'pepepowminer.sha256').write_text(f'{digest}  pepepowminer\n', encoding='utf-8')
(package / 'BUILD_PROFILE').write_text(
    '\n'.join([
        'release=PepeW Miner v1.0.9 V100 geometry autotune',
        f'source_commit={source_commit}',
        'build_type=Release',
        'cuda_toolkit=12.8.1',
        'cuda_architectures=70-real',
        'cuda_native=sm_70',
        'kernel_mode=volta-geometry-auto',
        'topology=exact-service-runtime-geometry',
        'dynamic_shared_scratch=true',
        'shared_bytes_formula=8+28*threads',
        'service_regions=3',
        'math_path=consensus-exact',
        'selector_path=consensus-exact',
        'cache_config=PreferL1',
        'shared_carveout=MaxL1',
        'autotune_candidates=96,128,160,192,224,256,288,320,352,384,416,448,480,512,544,576,608,640,672,704,736,768',
        'autotune_count=1048576',
        'autotune_rounds=3',
        'autotune_validation=6_cpu_gpu_nonces_per_candidate',
        'autotune_cache=per_gpu_uuid_and_binary_sha',
        'autotune_failure_policy=fail_closed',
        'chunk_size=262144',
        'fmad=false',
        'cpu_candidate_validation=consensus-exact',
        'hiveos_package_root=PepeW-Miner-v1.0.9',
        'hiveos_custom_name=PepeW-Miner-v1.0.9',
        'branding=Performance & Stability Edition',
        'slogan=PepeW - твоя монета. Твои правила.',
        f'binary_sha256={digest}',
        f'autotune_binary_sha256={bench_digest}',
        ''
    ]), encoding='utf-8')

for cache in package.rglob('__pycache__'):
    shutil.rmtree(cache, ignore_errors=True)

print(f'PACKAGE_DIR={package}')
print(f'HIVEOS_ROOT={root_name}')
print(f'BINARY_SHA256={digest}')
print(f'AUTOTUNE_BINARY_SHA256={bench_digest}')
