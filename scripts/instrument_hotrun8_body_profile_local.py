#!/usr/bin/env python3
from pathlib import Path
import runpy

# First apply the exact sparse body instrumentation, then convert the sampled
# per-cell global atomics into thread-local accumulators. Only one global flush
# per counter remains at the end of each sampled nonce.
runpy.run_path('scripts/instrument_hotrun8_body_profile.py', run_name='__main__')

hot = Path('native/src/cuda/v1/header80_hotrun8.inc')
s = hot.read_text()

old_sig = '''    int row, const std::uint32_t first_pass[8], double hash_mod_fp64,
    double nonce_mod, HooHashSwState& sw, bool profile_sample) {'''
new_sig = '''    int row, const std::uint32_t first_pass[8], double hash_mod_fp64,
    double nonce_mod, HooHashSwState& sw, bool profile_sample,
    unsigned long long& lp_warm, unsigned long long& lp_linear,
    unsigned long long& lp_sw, unsigned long long& lp_cold,
    unsigned long long& lp_warm_cells, unsigned long long& lp_cold_cells) {'''
if old_sig not in s:
    raise SystemExit('profiled matrix_row signature not found')
s = s.replace(old_sig, new_sig, 1)

repls = {
    'atomicAdd(&g_body_profile_warm_load_cycles, clock64() - profile_t0);': 'lp_warm += clock64() - profile_t0;',
    'atomicAdd(&g_body_profile_linear_accum_cycles, clock64() - profile_acc0);': 'lp_linear += clock64() - profile_acc0;',
    'atomicAdd(&g_body_profile_sw_cycles, clock64() - profile_sw0);': 'lp_sw += clock64() - profile_sw0;',
    'atomicAdd(&g_body_profile_cold_cycles, clock64() - profile_cold0);': 'lp_cold += clock64() - profile_cold0;',
    'atomicAdd(&g_body_profile_linear_accum_cycles, clock64() - profile_linear0);': 'lp_linear += clock64() - profile_linear0;',
    'atomicAdd(&g_body_profile_sw_cycles, clock64() - profile_sw1);': 'lp_sw += clock64() - profile_sw1;',
    'atomicAdd(&g_body_profile_warm_cells, 1ULL);': '++lp_warm_cells;',
    'atomicAdd(&g_body_profile_cold_cells, 1ULL);': '++lp_cold_cells;',
}
for old,new in repls.items():
    if old not in s:
        raise SystemExit(f'missing atomic anchor: {old}')
    s = s.replace(old,new)

setup = '''    const unsigned long long profile_total0 = profile_sample ? clock64() : 0ULL;
'''
setup2 = setup + '''    unsigned long long lp_warm = 0ULL;
    unsigned long long lp_linear = 0ULL;
    unsigned long long lp_sw = 0ULL;
    unsigned long long lp_cold = 0ULL;
    unsigned long long lp_warm_cells = 0ULL;
    unsigned long long lp_cold_cells = 0ULL;
'''
if setup not in s:
    raise SystemExit('profile total setup not found')
s = s.replace(setup, setup2, 1)

call = '''            hash_mod_fp64, nonce_mod, sw, profile_sample);'''
call2 = '''            hash_mod_fp64, nonce_mod, sw, profile_sample,
            lp_warm, lp_linear, lp_sw, lp_cold, lp_warm_cells, lp_cold_cells);'''
if s.count(call) != 2:
    raise SystemExit(f'expected 2 row calls, got {s.count(call)}')
s = s.replace(call, call2)

flush = '''    if (profile_sample) {
        atomicAdd(&g_body_profile_total_cycles, clock64() - profile_total0);
        atomicAdd(&g_body_profile_samples, 1ULL);
    }
'''
flush2 = '''    if (profile_sample) {
        const unsigned long long profile_total_delta = clock64() - profile_total0;
        atomicAdd(&g_body_profile_warm_load_cycles, lp_warm);
        atomicAdd(&g_body_profile_linear_accum_cycles, lp_linear);
        atomicAdd(&g_body_profile_sw_cycles, lp_sw);
        atomicAdd(&g_body_profile_cold_cycles, lp_cold);
        atomicAdd(&g_body_profile_warm_cells, lp_warm_cells);
        atomicAdd(&g_body_profile_cold_cells, lp_cold_cells);
        atomicAdd(&g_body_profile_total_cycles, profile_total_delta);
        atomicAdd(&g_body_profile_samples, 1ULL);
    }
'''
if flush not in s:
    raise SystemExit('final profile flush not found')
s = s.replace(flush, flush2, 1)

# Reduction is only 32 timings per sampled nonce and still used one global atomic
# per pair in v1. Accumulate it locally as well.
setup_reduce = '''    unsigned long long lp_cold_cells = 0ULL;
'''
if setup_reduce not in s:
    raise SystemExit('local counter setup not found')
s = s.replace(setup_reduce, setup_reduce + '    unsigned long long lp_reduce = 0ULL;\n', 1)
old_reduce = 'if (profile_sample) atomicAdd(&g_body_profile_reduce_cycles, clock64() - profile_reduce0);'
if old_reduce not in s:
    raise SystemExit('reduce atomic anchor not found')
s = s.replace(old_reduce, 'if (profile_sample) lp_reduce += clock64() - profile_reduce0;', 1)
flush_anchor = '        atomicAdd(&g_body_profile_cold_cycles, lp_cold);\n'
s = s.replace(flush_anchor, flush_anchor + '        atomicAdd(&g_body_profile_reduce_cycles, lp_reduce);\n', 1)

hot.write_text(s)
print('converted sparse body profiler to thread-local sampled accumulation')
