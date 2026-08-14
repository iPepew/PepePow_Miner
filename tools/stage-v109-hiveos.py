import hashlib
import os
import shutil
from pathlib import Path

version = '1.0.9'
root_name = f'PepeW-Miner-v{version}'
exact_build = Path(os.environ.get('PEPEW_BUILD_EXACT', 'build-v109-exact'))
fast_build = Path(os.environ.get('PEPEW_BUILD_FAST', 'build-v109-fast'))
stage_root = Path(os.environ.get('PEPEW_STAGE_ROOT', 'dist-stage'))
package = stage_root / root_name
source_commit = os.environ.get('GITHUB_SHA', 'unknown')

if package.exists():
    shutil.rmtree(package)
package.mkdir(parents=True, exist_ok=True)

files = {
    exact_build / 'pepepowminer': ('pepepowminer', 0o755),
    exact_build / 'pepepow_v100_autotune': ('pepepow-v100-autotune', 0o755),
    fast_build / 'pepepowminer': ('pepepowminer-fasttrig', 0o755),
    fast_build / 'pepepow_v100_autotune': ('pepepow-v100-autotune-fasttrig', 0o755),
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

s = s.replace(
    '[[ -x ./pepepowminer ]] || { echo "[ERROR] pepepowminer binary is missing or not executable" >&2; exit 1; }',
    '''[[ -x ./pepepowminer ]] || { echo "[ERROR] exact pepepowminer binary is missing or not executable" >&2; exit 1; }
[[ -x ./pepepowminer-fasttrig ]] || { echo "[ERROR] fasttrig pepepowminer binary is missing or not executable" >&2; exit 1; }
[[ -x ./pepepow-v100-autotune ]] || { echo "[ERROR] exact V100 autotuner is missing" >&2; exit 1; }
[[ -x ./pepepow-v100-autotune-fasttrig ]] || { echo "[ERROR] fasttrig V100 autotuner is missing" >&2; exit 1; }''',
    1,
)

old_array = 'declare -a gpu_indices gpu_uuids gpu_names gpu_buses gpu_memory gpu_sm gpu_profiles gpu_threads\n'
new_array = 'declare -a gpu_indices gpu_uuids gpu_names gpu_buses gpu_memory gpu_sm gpu_profiles gpu_threads gpu_modes\n'
if old_array not in s:
    raise SystemExit('h-run GPU array marker missing')
s = s.replace(old_array, new_array, 1)

old_thread_select = '''    if [[ "${PEPEPOW_CUDA_THREADS_RUNTIME}" == "auto" ]]; then
      threads="$(threads_for_sm "${sm}")"
    else
      threads="${PEPEPOW_CUDA_THREADS_RUNTIME}"
    fi
'''
new_thread_select = '''    trig_mode="exact"
    if [[ "${PEPEPOW_CUDA_THREADS_RUNTIME}" == "auto" ]]; then
      if [[ "${sm}" == "70" && -x "${miner_dir}/v100-autotune.sh" ]]; then
        selection="$("${miner_dir}/v100-autotune.sh" \
          "${miner_dir}" "${all_uuids[$position]}" "${log_dir}/gpu${index}-v100-autotune.log")"
        read -r threads trig_mode <<<"${selection}"
        if [[ "${trig_mode}" == "fasttrig" ]]; then
          profile="volta-fasttrig-auto"
        else
          trig_mode="exact"
          profile="volta-geometry-exact"
        fi
      else
        threads="$(threads_for_sm "${sm}")"
      fi
    else
      threads="${PEPEPOW_CUDA_THREADS_RUNTIME}"
      [[ "${sm}" == "70" ]] && profile="volta-geometry-manual"
    fi
'''
if old_thread_select not in s:
    raise SystemExit('h-run thread selection marker missing')
s = s.replace(old_thread_select, new_thread_select, 1)

old_append = '''    gpu_profiles+=("${profile}")
    gpu_threads+=("${threads}")
'''
new_append = '''    gpu_profiles+=("${profile}")
    gpu_threads+=("${threads}")
    gpu_modes+=("${trig_mode}")
'''
if old_append not in s:
    raise SystemExit('h-run GPU append marker missing')
s = s.replace(old_append, new_append, 1)

old_identity = 'miner_version="$(./pepepowminer --version 2>&1 | head -n1 || true)"\n'
new_identity = '''binary_identity="$(./pepepowminer --version 2>&1 | head -n1 || true)"
fast_binary_identity="$(./pepepowminer-fasttrig --version 2>&1 | head -n1 || true)"
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

old_gpu_line = '''  printf 'GPU %s | %s | sm_%s | %s | BUS %s | profile=%s | threads=%s | chunk=262144\\n' \\
    "${gpu_indices[$position]}" "${gpu_names[$position]}" "${gpu_sm[$position]}" \\
    "${gpu_memory[$position]}" "${gpu_buses[$position]}" "${gpu_profiles[$position]}" \\
    "${gpu_threads[$position]}"
'''
new_gpu_line = '''  printf 'GPU %s | %s | sm_%s | %s | BUS %s | engine=%s | profile=%s | threads=%s | chunk=262144\\n' \\
    "${gpu_indices[$position]}" "${gpu_names[$position]}" "${gpu_sm[$position]}" \\
    "${gpu_memory[$position]}" "${gpu_buses[$position]}" "${gpu_modes[$position]}" \\
    "${gpu_profiles[$position]}" "${gpu_threads[$position]}"
'''
if old_gpu_line not in s:
    raise SystemExit('h-run GPU startup line marker missing')
s = s.replace(old_gpu_line, new_gpu_line, 1)

s = s.replace('  echo "MINER_VERSION=${miner_version}"', '  echo "MINER_VERSION=${miner_version}"\n  echo "BINARY_IDENTITY=${binary_identity}"\n  echo "FAST_BINARY_IDENTITY=${fast_binary_identity}"')
s = s.replace(
    'profile=${gpu_profiles[$position]} threads=${gpu_threads[$position]} chunk=262144"',
    'engine=${gpu_modes[$position]} profile=${gpu_profiles[$position]} threads=${gpu_threads[$position]} chunk=262144"',
)

old_loop_vars = '''  gpu_profile="${gpu_profiles[$position]}"
  gpu_thread_count="${gpu_threads[$position]}"
  proxy_port=$((PEPEPOW_PROXY_PORT_BASE + position))
'''
new_loop_vars = '''  gpu_profile="${gpu_profiles[$position]}"
  gpu_thread_count="${gpu_threads[$position]}"
  gpu_mode="${gpu_modes[$position]}"
  worker_binary="./pepepowminer"
  [[ "${gpu_mode}" == "fasttrig" ]] && worker_binary="./pepepowminer-fasttrig"
  proxy_port=$((PEPEPOW_PROXY_PORT_BASE + position))
'''
if old_loop_vars not in s:
    raise SystemExit('h-run worker variable marker missing')
s = s.replace(old_loop_vars, new_loop_vars, 1)

old_start_worker = '''  printf '[START] GPU %s %s sm_%s profile=%s proxy_port=%s\\n' \\
    "${gpu_index}" "${gpu_name}" "${gpu_sm[$position]}" "${gpu_profile}" "${proxy_port}"
  CUDA_VISIBLE_DEVICES="${gpu_uuid}" \\
    PEPEW_PHYSICAL_GPU_INDEX="${gpu_index}" \\
    PEPEPOW_PROFILE="${gpu_profile}" \\
    PEPEPOW_CUDA_THREADS_RUNTIME="${gpu_thread_count}" \\
    PEPEPOW_STATS_INTERVAL="${PEPEPOW_STATS_INTERVAL}" \\
    ./pepepowminer "${args[@]}" >> "${console_log}" 2>&1 &
'''
new_start_worker = '''  printf '[START] GPU %s %s sm_%s engine=%s profile=%s threads=%s proxy_port=%s\\n' \\
    "${gpu_index}" "${gpu_name}" "${gpu_sm[$position]}" "${gpu_mode}" \\
    "${gpu_profile}" "${gpu_thread_count}" "${proxy_port}"
  CUDA_VISIBLE_DEVICES="${gpu_uuid}" \\
    PEPEW_PHYSICAL_GPU_INDEX="${gpu_index}" \\
    PEPEPOW_PROFILE="${gpu_profile}" \\
    PEPEPOW_CUDA_THREADS_RUNTIME="${gpu_thread_count}" \\
    PEPEPOW_STATS_INTERVAL="${PEPEPOW_STATS_INTERVAL}" \\
    "${worker_binary}" "${args[@]}" >> "${console_log}" 2>&1 &
'''
if old_start_worker not in s:
    raise SystemExit('h-run worker launch marker missing')
s = s.replace(old_start_worker, new_start_worker, 1)

old_worker_env = '''    printf 'GPU%s_PROFILE=%q\\n' "${index}" "${gpu_profiles[$position]}"
'''
new_worker_env = '''    printf 'GPU%s_PROFILE=%q\\n' "${index}" "${gpu_profiles[$position]}"
    printf 'GPU%s_MODE=%q\\n' "${index}" "${gpu_modes[$position]}"
'''
if old_worker_env not in s:
    raise SystemExit('h-run active worker profile marker missing')
s = s.replace(old_worker_env, new_worker_env, 1)

s = s.replace('v1.0.5', 'v1.0.9')
s = s.replace('PEPEW_V105_WRAPPER_GATE', 'PEPEW_V109_WRAPPER_GATE')
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
    'pepepowminer-fasttrig',
    'pepepow-v100-autotune-fasttrig',
    'volta-fasttrig-auto',
    'volta-geometry-exact',
    'PepeW Miner v1.0.9 - Performance & Stability Edition',
    'PepeW - твоя монета. Твои правила.',
):
    if required not in run_text:
        raise SystemExit(f'v1.0.9 h-run patch missing: {required}')

(package / 'VERSION').write_text(version + '\n', encoding='utf-8')
exact_binary = package / 'pepepowminer'
fast_binary = package / 'pepepowminer-fasttrig'
exact_digest = hashlib.sha256(exact_binary.read_bytes()).hexdigest()
fast_digest = hashlib.sha256(fast_binary.read_bytes()).hexdigest()
exact_tuner_digest = hashlib.sha256((package / 'pepepow-v100-autotune').read_bytes()).hexdigest()
fast_tuner_digest = hashlib.sha256((package / 'pepepow-v100-autotune-fasttrig').read_bytes()).hexdigest()
(package / 'pepepowminer.sha256').write_text(f'{exact_digest}  pepepowminer\n{fast_digest}  pepepowminer-fasttrig\n', encoding='utf-8')
(package / 'BUILD_PROFILE').write_text(
    '\n'.join([
        'release=PepeW Miner v1.0.9 V100 dual-engine autotune',
        f'source_commit={source_commit}',
        'build_type=Release',
        'cuda_toolkit=12.8.1',
        'cuda_architectures=70-real',
        'cuda_native=sm_70',
        'kernel_mode=volta-dual-auto',
        'engines=exact,fasttrig',
        'topology=service-runtime-geometry',
        'dynamic_shared_scratch=true',
        'shared_bytes_formula=8+28*threads',
        'service_regions=3',
        'exact_math_path=cuda_double_full_range',
        'fasttrig_path=restricted_2overpi128_dd_pio2_4chunk',
        'fasttrig_cuda_call=sincos_on_reduced_argument',
        'fasttrig_domain=2^31_to_2^57',
        'selector_path=consensus_exact',
        'cache_config=PreferL1',
        'shared_carveout=MaxL1',
        'autotune_modes=exact,fasttrig',
        'autotune_candidates=96,128,160,192,224,256,288,320,352,384,416,448,480,512,544,576,608,640,672,704,736,768',
        'autotune_count=1048576',
        'autotune_rounds=3',
        'autotune_validation=32_cpu_gpu_nonces_per_profile',
        'autotune_cache=per_gpu_uuid_and_dual_binary_sha',
        'autotune_failure_policy=fail_closed',
        'chunk_size=262144',
        'fmad=false',
        'cpu_candidate_validation=consensus-exact',
        'hiveos_package_root=PepeW-Miner-v1.0.9',
        'hiveos_custom_name=PepeW-Miner-v1.0.9',
        'branding=Performance & Stability Edition',
        'slogan=PepeW - твоя монета. Твои правила.',
        f'exact_binary_sha256={exact_digest}',
        f'fasttrig_binary_sha256={fast_digest}',
        f'exact_autotune_sha256={exact_tuner_digest}',
        f'fasttrig_autotune_sha256={fast_tuner_digest}',
        ''
    ]), encoding='utf-8')

for cache in package.rglob('__pycache__'):
    shutil.rmtree(cache, ignore_errors=True)

print(f'PACKAGE_DIR={package}')
print(f'HIVEOS_ROOT={root_name}')
print(f'EXACT_BINARY_SHA256={exact_digest}')
print(f'FASTTRIG_BINARY_SHA256={fast_digest}')
print(f'EXACT_AUTOTUNE_SHA256={exact_tuner_digest}')
print(f'FASTTRIG_AUTOTUNE_SHA256={fast_tuner_digest}')
