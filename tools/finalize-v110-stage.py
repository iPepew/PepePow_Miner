from pathlib import Path

root = Path('dist-stage/PepeW-Miner-v1.1.0')
profile = root / 'BUILD_PROFILE'
if not profile.exists():
    raise SystemExit(f'missing staged profile: {profile}')

text = profile.read_text(encoding='utf-8')
text = text.replace(
    'blocks_per_sm_candidates=4,8,10,12',
    'blocks_per_sm_candidates=1,2,4,8,10,12',
)
profile.write_text(text, encoding='utf-8')

required = (
    'blocks_per_sm_candidates=1,2,4,8,10,12',
    'cohort_thresholds=4,8,12,16,20,24,28,32',
    'autotune_validation=64_cpu_gpu_nonces_per_profile',
)
updated = profile.read_text(encoding='utf-8')
for marker in required:
    if marker not in updated:
        raise SystemExit(f'staged BUILD_PROFILE marker missing: {marker}')

print('V110_STAGE_METADATA_FINALIZE=PASS')
