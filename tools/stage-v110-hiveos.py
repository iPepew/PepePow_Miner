import hashlib
import os
import shutil
from pathlib import Path

version = '1.1.0'
root_name = f'PepeW-Miner-v{version}'
build_dir = Path(os.environ.get('PEPEW_BUILD_DIR', 'build-v110-v100'))
stage_root = Path(os.environ.get('PEPEW_STAGE_ROOT', 'dist-stage'))
package = stage_root / root_name
source_commit = os.environ.get('GITHUB_SHA', 'unknown')

if package.exists():
    shutil.rmtree(package)
package.mkdir(parents=True, exist_ok=True)

files = {
    build_dir / 'pepepowminer': ('pepepowminer', 0o755),
    build_dir / 'pepepow_v110_autotune': ('pepepow-v110-autotune', 0o755),
    Path('hiveos/h-config.sh'): ('h-config.sh', 0o755),
    Path('hiveos/h-run.sh'): ('h-run.sh', 0o755),
    Path('hiveos/h-stats.sh'): ('h-stats.sh', 0o755),
    Path('hiveos/console-monitor.sh'): ('console-monitor.sh', 0o755),
    Path('hiveos/stratum-replay-proxy.py'): ('stratum-replay-proxy.py', 0o755),
    Path('hiveos/v110-autotune.sh'): ('v110-autotune.sh', 0o755),
    Path('hiveos/h-manifest.conf'): ('h-manifest.conf', 0o644),
    Path('LICENSE'): ('LICENSE', 0o644),
    Path('README.md'): ('README.md', 0o644),
}
if Path('RELEASE_NOTES_v1.1.0.md').exists():
    files[Path('RELEASE_NOTES_v1.1.0.md')] = ('RELEASE_NOTES.md', 0o644)

for src, (name, mode) in files.items():
    if not src.exists():
        raise SystemExit(f'missing package input: {src}')
    dst = package / name
    shutil.copy2(src, dst)
    dst.chmod(mode)

run = package / 'h-run.sh'
s = run.read_text(encoding='utf-8')
s = s.replace(
    '[[ -x ./pepepowminer ]] || { echo "[ERROR] pepepowminer binary is missing or not executable" >&2; exit 1; }',
    '''[[ -x ./pepepowminer ]] || { echo "[ERROR] pepepowminer binary is missing or not executable" >&2; exit 1; }
[[ -x ./pepepow-v110-autotune ]] || { echo "[ERROR] v1.1.0 V100 autotune helper is missing" >&2; exit 1; }
[[ -x ./v110-autotune.sh ]] || { echo "[ERROR] v1.1.0 V100 autotune launcher is missing" >&2; exit 1; }''',
    1,
)
s = s.replace("    70) printf 'volta-auto' ;;", "    70) printf 'volta-cohort-auto' ;;")
s = s.replace("    70|120) printf '512' ;;", "    70) printf '768' ;;\n    120) printf '512' ;;")

old_arrays = 'declare -a gpu_indices gpu_uuids gpu_names gpu_buses gpu_memory gpu_sm gpu_profiles gpu_threads\n'
new_arrays = 'declare -a gpu_indices gpu_uuids gpu_names gpu_buses gpu_memory gpu_sm gpu_profiles gpu_threads gpu_engines gpu_thresholds gpu_blocks_per_sm gpu_bench_hps\n'
if old_arrays not in s:
    raise SystemExit('h-run GPU array marker missing')
s = s.replace(old_arrays, new_arrays, 1)

old_select = '''    if [[ "${PEPEPOW_CUDA_THREADS_RUNTIME}" == "auto" ]]; then
      threads="$(threads_for_sm "${sm}")"
    else
      threads="${PEPEPOW_CUDA_THREADS_RUNTIME}"
    fi
'''
new_select = '''    engine="exact"
    threshold="16"
    blocks_per_sm="10"
    benchmark_hps="0"
    if [[ "${PEPEPOW_CUDA_THREADS_RUNTIME}" == "auto" ]]; then
      if [[ "${sm}" == "70" ]]; then
        selection="$("${miner_dir}/v110-autotune.sh" \
          "${miner_dir}" "${all_uuids[$position]}" "${log_dir}/gpu${index}-v110-autotune.log")"
        read -r engine threads threshold blocks_per_sm benchmark_hps <<<"${selection}"
        if [[ "${engine}" == "cohort" ]]; then
          profile="volta-cohort256"
        else
          engine="exact"
          profile="volta-exact"
        fi
      else
        threads="$(threads_for_sm "${sm}")"
      fi
    else
      threads="${PEPEPOW_CUDA_THREADS_RUNTIME}"
      if [[ "${sm}" == "70" ]]; then
        profile="volta-exact-manual"
      fi
    fi
'''
if old_select not in s:
    raise SystemExit('h-run thread selection marker missing')
s = s.replace(old_select, new_select, 1)

old_append = '''    gpu_profiles+=("${profile}")
    gpu_threads+=("${threads}")
'''
new_append = '''    gpu_profiles+=("${profile}")
    gpu_threads+=("${threads}")
    gpu_engines+=("${engine}")
    gpu_thresholds+=("${threshold}")
    gpu_blocks_per_sm+=("${blocks_per_sm}")
    gpu_bench_hps+=("${benchmark_hps}")
'''
if old_append not in s:
    raise SystemExit('h-run append marker missing')
s = s.replace(old_append, new_append, 1)

old_identity = 'miner_version="$(./pepepowminer --version 2>&1 | head -n1 || true)"\n'
new_identity = '''binary_identity="$(./pepepowminer --version 2>&1 | head -n1 || true)"
miner_version="v1.1.0"
'''
if old_identity not in s:
    raise SystemExit('h-run miner identity marker missing')
s = s.replace(old_identity, new_identity, 1)

old_start = "printf '%s\\n' 'PepeW Miner startup'\n"
new_start = '''printf '\\n%s\\n' 'PepeW Miner v1.1.0 - Performance & Stability Edition'
printf '%s\\n' 'PepeW - твоя монета. Твои правила.'
printf '%s\\n' '------------------------------------------------------------'
'''
if old_start not in s:
    raise SystemExit('h-run startup marker missing')
s = s.replace(old_start, new_start, 1)

old_gpu_line = '''  printf 'GPU %s | %s | sm_%s | %s | BUS %s | profile=%s | threads=%s | chunk=262144\\n' \\
    "${gpu_indices[$position]}" "${gpu_names[$position]}" "${gpu_sm[$position]}" \\
    "${gpu_memory[$position]}" "${gpu_buses[$position]}" "${gpu_profiles[$position]}" \\
    "${gpu_threads[$position]}"
'''
new_gpu_line = '''  benchmark_mhs="$(awk -v h="${gpu_bench_hps[$position]}" 'BEGIN {printf "%.3f", h/1000000.0}')"
  printf 'GPU %s | %s | sm_%s | %s | BUS %s | engine=%s | profile=%s | threads=%s | cohort=%s | blocks/SM=%s | tune=%s MH/s | chunk=262144\\n' \\
    "${gpu_indices[$position]}" "${gpu_names[$position]}" "${gpu_sm[$position]}" \\
    "${gpu_memory[$position]}" "${gpu_buses[$position]}" "${gpu_engines[$position]}" \\
    "${gpu_profiles[$position]}" "${gpu_threads[$position]}" "${gpu_thresholds[$position]}" \\
    "${gpu_blocks_per_sm[$position]}" "${benchmark_mhs}"
'''
if old_gpu_line not in s:
    raise SystemExit('h-run GPU display marker missing')
s = s.replace(old_gpu_line, new_gpu_line, 1)

s = s.replace('  echo "MINER_VERSION=${miner_version}"', '  echo "MINER_VERSION=${miner_version}"\n  echo "BINARY_IDENTITY=${binary_identity}"')
old_diag = 'echo "GPU${gpu_indices[$position]}=${gpu_names[$position]} uuid=${gpu_uuids[$position]} bus=${gpu_buses[$position]} sm=${gpu_sm[$position]} profile=${gpu_profiles[$position]} threads=${gpu_threads[$position]} chunk=262144"'
new_diag = 'echo "GPU${gpu_indices[$position]}=${gpu_names[$position]} uuid=${gpu_uuids[$position]} bus=${gpu_buses[$position]} sm=${gpu_sm[$position]} engine=${gpu_engines[$position]} profile=${gpu_profiles[$position]} threads=${gpu_threads[$position]} cohort=${gpu_thresholds[$position]} blocks_per_sm=${gpu_blocks_per_sm[$position]} tune_hps=${gpu_bench_hps[$position]} chunk=262144"'
if old_diag not in s:
    raise SystemExit('h-run diagnostics marker missing')
s = s.replace(old_diag, new_diag, 1)

old_worker_vars = '''  gpu_profile="${gpu_profiles[$position]}"
  gpu_thread_count="${gpu_threads[$position]}"
  proxy_port=$((PEPEPOW_PROXY_PORT_BASE + position))
'''
new_worker_vars = '''  gpu_profile="${gpu_profiles[$position]}"
  gpu_thread_count="${gpu_threads[$position]}"
  gpu_engine="${gpu_engines[$position]}"
  gpu_threshold="${gpu_thresholds[$position]}"
  gpu_blocks_sm="${gpu_blocks_per_sm[$position]}"
  proxy_port=$((PEPEPOW_PROXY_PORT_BASE + position))
'''
if old_worker_vars not in s:
    raise SystemExit('h-run worker variable marker missing')
s = s.replace(old_worker_vars, new_worker_vars, 1)

old_worker_launch = '''  printf '[START] GPU %s %s sm_%s profile=%s proxy_port=%s\\n' \\
    "${gpu_index}" "${gpu_name}" "${gpu_sm[$position]}" "${gpu_profile}" "${proxy_port}"
  CUDA_VISIBLE_DEVICES="${gpu_uuid}" \\
    PEPEW_PHYSICAL_GPU_INDEX="${gpu_index}" \\
    PEPEPOW_PROFILE="${gpu_profile}" \\
    PEPEPOW_CUDA_THREADS_RUNTIME="${gpu_thread_count}" \\
    PEPEPOW_STATS_INTERVAL="${PEPEPOW_STATS_INTERVAL}" \\
    ./pepepowminer "${args[@]}" >> "${console_log}" 2>&1 &
'''
new_worker_launch = '''  printf '[START] GPU %s %s sm_%s engine=%s profile=%s threads=%s cohort=%s blocks/SM=%s proxy_port=%s\\n' \\
    "${gpu_index}" "${gpu_name}" "${gpu_sm[$position]}" "${gpu_engine}" \\
    "${gpu_profile}" "${gpu_thread_count}" "${gpu_threshold}" "${gpu_blocks_sm}" "${proxy_port}"
  CUDA_VISIBLE_DEVICES="${gpu_uuid}" \\
    PEPEW_PHYSICAL_GPU_INDEX="${gpu_index}" \\
    PEPEPOW_PROFILE="${gpu_profile}" \\
    PEPEPOW_CUDA_THREADS_RUNTIME="${gpu_thread_count}" \\
    PEPEPOW_V110_ENGINE="${gpu_engine}" \\
    PEPEPOW_V110_COHORT_THRESHOLD="${gpu_threshold}" \\
    PEPEPOW_V110_BLOCKS_PER_SM="${gpu_blocks_sm}" \\
    PEPEPOW_STATS_INTERVAL="${PEPEPOW_STATS_INTERVAL}" \\
    ./pepepowminer "${args[@]}" >> "${console_log}" 2>&1 &
'''
if old_worker_launch not in s:
    raise SystemExit('h-run worker launch marker missing')
s = s.replace(old_worker_launch, new_worker_launch, 1)

old_worker_profile = '''    printf 'GPU%s_PROFILE=%q\\n' "${index}" "${gpu_profiles[$position]}"
'''
new_worker_profile = '''    printf 'GPU%s_PROFILE=%q\\n' "${index}" "${gpu_profiles[$position]}"
    printf 'GPU%s_ENGINE=%q\\n' "${index}" "${gpu_engines[$position]}"
    printf 'GPU%s_COHORT_THRESHOLD=%q\\n' "${index}" "${gpu_thresholds[$position]}"
    printf 'GPU%s_BLOCKS_PER_SM=%q\\n' "${index}" "${gpu_blocks_per_sm[$position]}"
    printf 'GPU%s_TUNE_HPS=%q\\n' "${index}" "${gpu_bench_hps[$position]}"
'''
if old_worker_profile not in s:
    raise SystemExit('h-run active worker marker missing')
s = s.replace(old_worker_profile, new_worker_profile, 1)

s = s.replace('This v1.0.5 build supports', 'This v1.1.0 build supports')
s = s.replace('PEPEW_V105_WRAPPER_GATE', 'PEPEW_V110_WRAPPER_GATE')
s = s.replace('[READY] PepeW Miner v1.0.5 workers started:', '[READY] PepeW Miner v1.1.0 workers started:')
run.write_text(s, encoding='utf-8')
run.chmod(0o755)

cfg = package / 'h-config.sh'
cfg_text = cfg.read_text(encoding='utf-8')
cfg_text = cfg_text.replace('v1.0.9', 'v1.1.0').replace('1.0.9', '1.1.0')
cfg.write_text(cfg_text, encoding='utf-8')
cfg.chmod(0o755)

manifest = (package / 'h-manifest.conf').read_text(encoding='utf-8')
for expected in (
    'CUSTOM_NAME=PepeW-Miner-v1.1.0',
    'CUSTOM_VERSION=1.1.0',
    'CUSTOM_CONFIG_FILENAME=/hive/miners/custom/PepeW-Miner-v1.1.0/config.txt',
):
    if expected not in manifest:
        raise SystemExit(f'v1.1.0 manifest verification failed: {expected}')

run_text = run.read_text(encoding='utf-8')
for required in (
    'v110-autotune.sh',
    'pepepow-v110-autotune',
    'PEPEPOW_V110_ENGINE',
    'PEPEPOW_V110_COHORT_THRESHOLD',
    'PEPEPOW_V110_BLOCKS_PER_SM',
    'volta-cohort256',
    'volta-exact',
    'PepeW Miner v1.1.0 - Performance & Stability Edition',
    'PepeW - твоя монета. Твои правила.',
):
    if required not in run_text:
        raise SystemExit(f'v1.1.0 h-run patch missing: {required}')

(package / 'VERSION').write_text(version + '\n', encoding='utf-8')
binary = package / 'pepepowminer'
digest = hashlib.sha256(binary.read_bytes()).hexdigest()
tuner_digest = hashlib.sha256((package / 'pepepow-v110-autotune').read_bytes()).hexdigest()
(package / 'pepepowminer.sha256').write_text(f'{digest}  pepepowminer\n', encoding='utf-8')
(package / 'BUILD_PROFILE').write_text(
    '\n'.join([
        'release=PepeW Miner v1.1.0 V100 persistent warp cohort',
        f'source_commit={source_commit}',
        'build_type=Release',
        'cuda_toolkit=12.8.1',
        'cuda_architectures=70-real',
        'cuda_native=sm_70',
        'kernel_modes=exact-service768,warp-cohort256',
        'new_engine=warp-cohort-persistent',
        'cohort_threads=256',
        'cohort_thresholds=4,8,12,16,20,24,28,32',
        'blocks_per_sm_candidates=4,8,10,12',
        'persistent_grid=true',
        'persistent_batch_reference=1228800',
        'hot_loop_block_barriers_cohort=0',
        'shared_queue_cohort=false',
        'shared_atomics_cohort=false',
        'nonlinear_batching=warp-time-cohort',
        'exact_fallback=service768',
        'autotune_validation=64_cpu_gpu_nonces_per_profile',
        'autotune_rounds=3',
        'autotune_selection_margin=2_percent_over_exact',
        'autotune_failure_policy=exact_fail_closed',
        'math_path=consensus-exact',
        'fmad=false',
        'cpu_candidate_validation=consensus-exact',
        'hiveos_package_root=PepeW-Miner-v1.1.0',
        'hiveos_custom_name=PepeW-Miner-v1.1.0',
        'branding=Performance & Stability Edition',
        'slogan=PepeW - твоя монета. Твои правила.',
        f'binary_sha256={digest}',
        f'autotune_binary_sha256={tuner_digest}',
        ''
    ]), encoding='utf-8')

for cache in package.rglob('__pycache__'):
    shutil.rmtree(cache, ignore_errors=True)

print(f'PACKAGE_DIR={package}')
print(f'HIVEOS_ROOT={root_name}')
print(f'BINARY_SHA256={digest}')
print(f'AUTOTUNE_BINARY_SHA256={tuner_digest}')
