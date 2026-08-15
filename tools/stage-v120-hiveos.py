import hashlib
import os
import shutil
from pathlib import Path

version = '1.2.0'
root_name = f'PepeW-Miner-v{version}'
build_dir = Path(os.environ.get('PEPEW_BUILD_DIR', 'build-v120-v100'))
stage_root = Path(os.environ.get('PEPEW_STAGE_ROOT', 'dist-stage'))
package = stage_root / root_name
source_commit = os.environ.get('GITHUB_SHA', 'unknown')

if package.exists():
    shutil.rmtree(package)
package.mkdir(parents=True, exist_ok=True)

files = {
    build_dir / 'pepepowminer': ('pepepowminer', 0o755),
    build_dir / 'pepepow_v120_autotune': ('pepepow-v120-autotune', 0o755),
    Path('hiveos/h-config.sh'): ('h-config.sh', 0o755),
    Path('hiveos/h-run.sh'): ('h-run.sh', 0o755),
    Path('hiveos/h-stats.sh'): ('h-stats.sh', 0o755),
    Path('hiveos/console-monitor.sh'): ('console-monitor.sh', 0o755),
    Path('hiveos/stratum-replay-proxy.py'): ('stratum-replay-proxy.py', 0o755),
    Path('hiveos/v120-autotune.sh'): ('v120-autotune.sh', 0o755),
    Path('hiveos/h-manifest.conf'): ('h-manifest.conf', 0o644),
    Path('LICENSE'): ('LICENSE', 0o644),
    Path('README.md'): ('README.md', 0o644),
}
if Path('RELEASE_NOTES_v1.2.0.md').exists():
    files[Path('RELEASE_NOTES_v1.2.0.md')] = ('RELEASE_NOTES.md', 0o644)

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
[[ -x ./pepepow-v120-autotune ]] || { echo "[ERROR] v1.2.0 V100 autotune helper is missing" >&2; exit 1; }
[[ -x ./v120-autotune.sh ]] || { echo "[ERROR] v1.2.0 V100 autotune launcher is missing" >&2; exit 1; }''',
    1,
)
s = s.replace("    70) printf 'volta-auto' ;;", "    70) printf 'volta-magic-auto' ;;")
s = s.replace("    70|120) printf '512' ;;", "    70) printf '768' ;;\n    120) printf '512' ;;")

old_arrays = 'declare -a gpu_indices gpu_uuids gpu_names gpu_buses gpu_memory gpu_sm gpu_profiles gpu_threads\n'
new_arrays = 'declare -a gpu_indices gpu_uuids gpu_names gpu_buses gpu_memory gpu_sm gpu_profiles gpu_threads gpu_engines gpu_blocks_per_sm gpu_fast_rsqrt gpu_raw_hps gpu_effective_hps gpu_quality gpu_chunks\n'
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
    blocks_per_sm="1"
    fast_rsqrt="0"
    raw_hps="0"
    effective_hps="0"
    quality="1.000000"
    chunk_size="262144"
    if [[ "${PEPEPOW_CUDA_THREADS_RUNTIME}" == "auto" ]]; then
      if [[ "${sm}" == "70" ]]; then
        selection="$("${miner_dir}/v120-autotune.sh" \
          "${miner_dir}" "${all_uuids[$position]}" "${log_dir}/gpu${index}-v120-autotune.log")"
        read -r engine threads blocks_per_sm fast_rsqrt raw_hps effective_hps quality <<<"${selection}"
        if [[ "${engine}" == "magic" ]]; then
          profile="volta-magic-lut"
          chunk_size="1228800"
        else
          engine="exact"
          profile="volta-exact"
          chunk_size="262144"
        fi
      else
        threads="$(threads_for_sm "${sm}")"
      fi
    else
      threads="${PEPEPOW_CUDA_THREADS_RUNTIME}"
      if [[ "${sm}" == "70" ]]; then profile="volta-exact-manual"; fi
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
    gpu_blocks_per_sm+=("${blocks_per_sm}")
    gpu_fast_rsqrt+=("${fast_rsqrt}")
    gpu_raw_hps+=("${raw_hps}")
    gpu_effective_hps+=("${effective_hps}")
    gpu_quality+=("${quality}")
    gpu_chunks+=("${chunk_size}")
'''
if old_append not in s:
    raise SystemExit('h-run GPU append marker missing')
s = s.replace(old_append, new_append, 1)

old_identity = 'miner_version="$(./pepepowminer --version 2>&1 | head -n1 || true)"\n'
new_identity = '''binary_identity="$(./pepepowminer --version 2>&1 | head -n1 || true)"
miner_version="v1.2.0"
'''
if old_identity not in s:
    raise SystemExit('h-run miner identity marker missing')
s = s.replace(old_identity, new_identity, 1)

old_start = "printf '%s\\n' 'PepeW Miner startup'\n"
new_start = '''printf '\\n%s\\n' 'PepeW Miner v1.2.0 - Performance & Stability Edition'
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
new_gpu_line = '''  raw_mhs="$(awk -v h="${gpu_raw_hps[$position]}" 'BEGIN {printf "%.3f", h/1000000.0}')"
  effective_mhs="$(awk -v h="${gpu_effective_hps[$position]}" 'BEGIN {printf "%.3f", h/1000000.0}')"
  printf 'GPU %s | %s | sm_%s | %s | BUS %s | engine=%s | profile=%s | threads=%s | blocks/SM=%s | rsqrt=%s | quality=%s | tune=%s/%s MH/s raw/effective | chunk=%s\\n' \\
    "${gpu_indices[$position]}" "${gpu_names[$position]}" "${gpu_sm[$position]}" \\
    "${gpu_memory[$position]}" "${gpu_buses[$position]}" "${gpu_engines[$position]}" \\
    "${gpu_profiles[$position]}" "${gpu_threads[$position]}" "${gpu_blocks_per_sm[$position]}" \\
    "${gpu_fast_rsqrt[$position]}" "${gpu_quality[$position]}" "${raw_mhs}" "${effective_mhs}" \\
    "${gpu_chunks[$position]}"
'''
if old_gpu_line not in s:
    raise SystemExit('h-run GPU display marker missing')
s = s.replace(old_gpu_line, new_gpu_line, 1)

s = s.replace('  echo "MINER_VERSION=${miner_version}"', '  echo "MINER_VERSION=${miner_version}"\n  echo "BINARY_IDENTITY=${binary_identity}"')
old_diag = 'echo "GPU${gpu_indices[$position]}=${gpu_names[$position]} uuid=${gpu_uuids[$position]} bus=${gpu_buses[$position]} sm=${gpu_sm[$position]} profile=${gpu_profiles[$position]} threads=${gpu_threads[$position]} chunk=262144"'
new_diag = 'echo "GPU${gpu_indices[$position]}=${gpu_names[$position]} uuid=${gpu_uuids[$position]} bus=${gpu_buses[$position]} sm=${gpu_sm[$position]} engine=${gpu_engines[$position]} profile=${gpu_profiles[$position]} threads=${gpu_threads[$position]} blocks_per_sm=${gpu_blocks_per_sm[$position]} fast_rsqrt=${gpu_fast_rsqrt[$position]} raw_hps=${gpu_raw_hps[$position]} effective_hps=${gpu_effective_hps[$position]} quality=${gpu_quality[$position]} chunk=${gpu_chunks[$position]}"'
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
  gpu_blocks_sm="${gpu_blocks_per_sm[$position]}"
  gpu_rsqrt="${gpu_fast_rsqrt[$position]}"
  gpu_chunk="${gpu_chunks[$position]}"
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
new_worker_launch = '''  printf '[START] GPU %s %s sm_%s engine=%s profile=%s threads=%s blocks/SM=%s rsqrt=%s chunk=%s proxy_port=%s\\n' \\
    "${gpu_index}" "${gpu_name}" "${gpu_sm[$position]}" "${gpu_engine}" \\
    "${gpu_profile}" "${gpu_thread_count}" "${gpu_blocks_sm}" "${gpu_rsqrt}" "${gpu_chunk}" "${proxy_port}"
  CUDA_VISIBLE_DEVICES="${gpu_uuid}" \\
    PEPEW_PHYSICAL_GPU_INDEX="${gpu_index}" \\
    PEPEPOW_PROFILE="${gpu_profile}" \\
    PEPEPOW_CUDA_THREADS_RUNTIME="${gpu_thread_count}" \\
    PEPEPOW_V120_ENGINE="${gpu_engine}" \\
    PEPEPOW_V120_BLOCKS_PER_SM="${gpu_blocks_sm}" \\
    PEPEPOW_V120_FAST_RSQRT="${gpu_rsqrt}" \\
    PEPEPOW_CHUNK_SIZE="${gpu_chunk}" \\
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
    printf 'GPU%s_BLOCKS_PER_SM=%q\\n' "${index}" "${gpu_blocks_per_sm[$position]}"
    printf 'GPU%s_FAST_RSQRT=%q\\n' "${index}" "${gpu_fast_rsqrt[$position]}"
    printf 'GPU%s_RAW_HPS=%q\\n' "${index}" "${gpu_raw_hps[$position]}"
    printf 'GPU%s_EFFECTIVE_HPS=%q\\n' "${index}" "${gpu_effective_hps[$position]}"
    printf 'GPU%s_QUALITY=%q\\n' "${index}" "${gpu_quality[$position]}"
    printf 'GPU%s_CHUNK=%q\\n' "${index}" "${gpu_chunks[$position]}"
'''
if old_worker_profile not in s:
    raise SystemExit('h-run active worker marker missing')
s = s.replace(old_worker_profile, new_worker_profile, 1)

s = s.replace('This v1.0.5 build supports', 'This v1.2.0 build supports')
s = s.replace('PEPEW_V105_WRAPPER_GATE', 'PEPEW_V120_WRAPPER_GATE')
s = s.replace('[READY] PepeW Miner v1.0.5 workers started:', '[READY] PepeW Miner v1.2.0 workers started:')
run.write_text(s, encoding='utf-8')
run.chmod(0o755)

cfg = package / 'h-config.sh'
cfg_text = cfg.read_text(encoding='utf-8')
for old in ('v1.1.0', 'v1.0.9', 'v1.0.5'):
    cfg_text = cfg_text.replace(old, 'v1.2.0')
for old in ('1.1.0', '1.0.9', '1.0.5'):
    cfg_text = cfg_text.replace(old, '1.2.0')
cfg.write_text(cfg_text, encoding='utf-8')
cfg.chmod(0o755)

manifest = (package / 'h-manifest.conf').read_text(encoding='utf-8')
for expected in (
    'CUSTOM_NAME=PepeW-Miner-v1.2.0',
    'CUSTOM_VERSION=1.2.0',
    'CUSTOM_CONFIG_FILENAME=/hive/miners/custom/PepeW-Miner-v1.2.0/config.txt',
):
    if expected not in manifest:
        raise SystemExit(f'v1.2.0 manifest verification failed: {expected}')

run_text = run.read_text(encoding='utf-8')
for required in (
    'v120-autotune.sh',
    'pepepow-v120-autotune',
    'PEPEPOW_V120_ENGINE',
    'PEPEPOW_V120_BLOCKS_PER_SM',
    'PEPEPOW_V120_FAST_RSQRT',
    'PEPEPOW_CHUNK_SIZE',
    'volta-magic-lut',
    'volta-exact',
    'PepeW Miner v1.2.0 - Performance & Stability Edition',
    'PepeW - твоя монета. Твои правила.',
):
    if required not in run_text:
        raise SystemExit(f'v1.2.0 h-run patch missing: {required}')

(package / 'VERSION').write_text(version + '\n', encoding='utf-8')
binary = package / 'pepepowminer'
tuner = package / 'pepepow-v120-autotune'
digest = hashlib.sha256(binary.read_bytes()).hexdigest()
tuner_digest = hashlib.sha256(tuner.read_bytes()).hexdigest()
(package / 'pepepowminer.sha256').write_text(f'{digest}  pepepowminer\n', encoding='utf-8')
(package / 'BUILD_PROFILE').write_text(
    '\n'.join([
        'release=PepeW Miner v1.2.0 V100 Magic LUT Solver',
        f'source_commit={source_commit}',
        'build_type=Release',
        'cuda_toolkit=12.8.1',
        'cuda_architectures=70-real',
        'cuda_native=sm_70',
        'kernel_modes=exact-service768,magic-lut-persistent',
        'new_engine=magic-lut-speculative',
        'magic_lut_nodes=65536',
        'magic_lut_interpolation=cubic-hermite-fp64',
        'magic_lut_functions=exp(sin+cos),sin^2',
        'magic_phase=fixedpoint-2overpi-128bit-direct',
        'magic_phase_domain=2^31_to_2^57',
        'magic_warm_path=constant-scaled-matrix-plus-fp64-multiply',
        'magic_warm_table_bytes=32768',
        'magic_lut_bytes=2097152',
        'magic_threads=128,256',
        'magic_blocks_per_sm=1,2,4,6,8',
        'magic_fast_rsqrt=autotune_0_or_1_newton_step',
        'magic_batch=1228800',
        'exact_batch=262144',
        'physical_autotune_score=raw_hps_times_exact_hash_quality',
        'physical_autotune_validation=256_cpu_gpu_hashes_per_profile',
        'physical_autotune_min_quality=0.90',
        'physical_autotune_selection_margin=1.05x_exact',
        'cpu_candidate_validation=consensus-exact',
        'exact_fallback=service768',
        'fmad=false',
        'hiveos_package_root=PepeW-Miner-v1.2.0',
        'hiveos_custom_name=PepeW-Miner-v1.2.0',
        'branding=Performance & Stability Edition',
        'slogan=PepeW - твоя монета. Твои правила.',
        f'binary_sha256={digest}',
        f'autotune_sha256={tuner_digest}',
        ''
    ]), encoding='utf-8')

for cache in package.rglob('__pycache__'):
    shutil.rmtree(cache, ignore_errors=True)

print(f'PACKAGE_DIR={package}')
print(f'HIVEOS_ROOT={root_name}')
print(f'BINARY_SHA256={digest}')
print(f'AUTOTUNE_SHA256={tuner_digest}')
