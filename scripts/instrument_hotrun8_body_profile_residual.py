#!/usr/bin/env python3
from pathlib import Path
import runpy

# Start from the low-distortion sparse body profiler, then add coarse-grained
# timers that decompose the remaining residual without introducing per-cell
# global atomics. Exact HooHash arithmetic is untouched.
runpy.run_path('scripts/instrument_hotrun8_body_profile_local.py', run_name='__main__')

hot = Path('native/src/cuda/v1/header80_hotrun8.inc')
s = hot.read_text()

# Add coarse global counters. These are flushed once per sampled nonce.
anchor = '__device__ unsigned long long g_body_profile_cold_cells = 0ULL;\n'
extra = anchor + '''__device__ unsigned long long g_body_profile_init_cycles = 0ULL;\n__device__ unsigned long long g_body_profile_row_cycles = 0ULL;\n__device__ unsigned long long g_body_profile_pair_outer_cycles = 0ULL;\n'''
if anchor not in s:
    raise SystemExit('body-profile counter anchor not found')
s = s.replace(anchor, extra, 1)

# Local accumulators.
anchor = '    unsigned long long lp_reduce = 0ULL;\n'
extra = anchor + '''    unsigned long long lp_init = 0ULL;\n    unsigned long long lp_row = 0ULL;\n    unsigned long long lp_pair_outer = 0ULL;\n'''
if anchor not in s:
    raise SystemExit('local reduce counter anchor not found')
s = s.replace(anchor, extra, 1)

# Time only the initialization after sampling decision is available. This is a
# nonce-level coarse bucket and adds two clock64 reads per sampled nonce.
old = '''    const bool profile_sample = (first_pass[0] & 0x0fffU) == 0U;\n    const unsigned long long profile_total0 = profile_sample ? clock64() : 0ULL;\n#else\n'''
new = '''    const bool profile_sample = (first_pass[0] & 0x0fffU) == 0U;\n    const unsigned long long profile_total0 = profile_sample ? clock64() : 0ULL;\n    const unsigned long long profile_init0 = profile_sample ? clock64() : 0ULL;\n#else\n'''
if old not in s:
    raise SystemExit('sampling setup anchor not found')
s = s.replace(old, new, 1)

old = '''    #pragma unroll 1\n    for (int pair = 0; pair < 32; ++pair) {\n        const double even_sum = matrix_row_hotrun8(\n'''
new = '''#if defined(PEPEPOW_CUDA_BODY_PROFILE) && PEPEPOW_CUDA_BODY_PROFILE\n    if (profile_sample) lp_init += clock64() - profile_init0;\n#endif\n    #pragma unroll 1\n    for (int pair = 0; pair < 32; ++pair) {\n#if defined(PEPEPOW_CUDA_BODY_PROFILE) && PEPEPOW_CUDA_BODY_PROFILE\n        const unsigned long long profile_row0 = profile_sample ? clock64() : 0ULL;\n#endif\n        const double even_sum = matrix_row_hotrun8(\n'''
if old not in s:
    raise SystemExit('pair loop anchor not found')
s = s.replace(old, new, 1)

# Stop row timer after both row calls. Then separately time pair-level conversion
# and mixed-word update. Existing reduce timer remains for cross-checking.
old = '''        const double odd_sum = matrix_row_hotrun8(\n            matrix, scaled_nibble_table, pair * 2 + 1, first_pass,\n            hash_mod_fp64, nonce_mod, sw, profile_sample,\n            lp_warm, lp_linear, lp_sw, lp_cold, lp_warm_cells, lp_cold_cells);\n#if defined(PEPEPOW_CUDA_BODY_PROFILE) && PEPEPOW_CUDA_BODY_PROFILE\n        const unsigned long long profile_reduce0 = profile_sample ? clock64() : 0ULL;\n#endif\n'''
new = '''        const double odd_sum = matrix_row_hotrun8(\n            matrix, scaled_nibble_table, pair * 2 + 1, first_pass,\n            hash_mod_fp64, nonce_mod, sw, profile_sample,\n            lp_warm, lp_linear, lp_sw, lp_cold, lp_warm_cells, lp_cold_cells);\n#if defined(PEPEPOW_CUDA_BODY_PROFILE) && PEPEPOW_CUDA_BODY_PROFILE\n        if (profile_sample) lp_row += clock64() - profile_row0;\n        const unsigned long long profile_pair_outer0 = profile_sample ? clock64() : 0ULL;\n        const unsigned long long profile_reduce0 = profile_pair_outer0;\n#endif\n'''
if old not in s:
    raise SystemExit('odd-row/reduce anchor not found')
s = s.replace(old, new, 1)

old = '''        if (profile_sample) lp_reduce += clock64() - profile_reduce0;\n#endif\n'''
new = '''        if (profile_sample) {\n            const unsigned long long profile_pair_outer_delta = clock64() - profile_pair_outer0;\n            lp_reduce += profile_pair_outer_delta;\n            lp_pair_outer += profile_pair_outer_delta;\n        }\n#endif\n'''
if old not in s:
    raise SystemExit('reduce local anchor not found')
s = s.replace(old, new, 1)

# Flush new counters once per sampled nonce.
anchor = '        atomicAdd(&g_body_profile_reduce_cycles, lp_reduce);\n'
extra = anchor + '''        atomicAdd(&g_body_profile_init_cycles, lp_init);\n        atomicAdd(&g_body_profile_row_cycles, lp_row);\n        atomicAdd(&g_body_profile_pair_outer_cycles, lp_pair_outer);\n'''
if anchor not in s:
    raise SystemExit('flush anchor not found')
s = s.replace(anchor, extra, 1)
hot.write_text(s)

part = Path('native/src/cuda/v1/header80_backend_part07.inc')
p = part.read_text()

# Reset new counters.
anchor = '    check_cuda_header80(cudaMemcpyToSymbol(g_body_profile_cold_cells, &profile_zero, sizeof(profile_zero)), "reset body cold cells");\n'
extra = anchor + '''    check_cuda_header80(cudaMemcpyToSymbol(g_body_profile_init_cycles, &profile_zero, sizeof(profile_zero)), "reset body init");\n    check_cuda_header80(cudaMemcpyToSymbol(g_body_profile_row_cycles, &profile_zero, sizeof(profile_zero)), "reset body row");\n    check_cuda_header80(cudaMemcpyToSymbol(g_body_profile_pair_outer_cycles, &profile_zero, sizeof(profile_zero)), "reset body pair outer");\n'''
if anchor not in p:
    raise SystemExit('host reset anchor not found')
p = p.replace(anchor, extra, 1)

old = '    unsigned long long profile_total=0, profile_warm=0, profile_linear=0, profile_sw=0, profile_cold=0, profile_reduce=0, profile_samples=0, profile_warm_cells=0, profile_cold_cells=0;\n'
new = '    unsigned long long profile_total=0, profile_warm=0, profile_linear=0, profile_sw=0, profile_cold=0, profile_reduce=0, profile_samples=0, profile_warm_cells=0, profile_cold_cells=0, profile_init=0, profile_row=0, profile_pair_outer=0;\n'
if old not in p:
    raise SystemExit('host local declaration anchor not found')
p = p.replace(old, new, 1)

anchor = '    check_cuda_header80(cudaMemcpyFromSymbol(&profile_cold_cells, g_body_profile_cold_cells, sizeof(profile_cold_cells)), "copy body cold cells");\n'
extra = anchor + '''    check_cuda_header80(cudaMemcpyFromSymbol(&profile_init, g_body_profile_init_cycles, sizeof(profile_init)), "copy body init");\n    check_cuda_header80(cudaMemcpyFromSymbol(&profile_row, g_body_profile_row_cycles, sizeof(profile_row)), "copy body row");\n    check_cuda_header80(cudaMemcpyFromSymbol(&profile_pair_outer, g_body_profile_pair_outer_cycles, sizeof(profile_pair_outer)), "copy body pair outer");\n'''
if anchor not in p:
    raise SystemExit('host copy anchor not found')
p = p.replace(anchor, extra, 1)

old = '''        "PEPEW_BODY_PROFILE count=%zu samples=%llu total_cycles=%llu warm_load_cycles=%llu linear_accum_cycles=%llu sw_cycles=%llu cold_cycles=%llu reduce_cycles=%llu residual_cycles=%llu warm_cells=%llu cold_cells=%llu\\n",\n        count, profile_samples, profile_total, profile_warm, profile_linear, profile_sw, profile_cold, profile_reduce, profile_residual, profile_warm_cells, profile_cold_cells);\n'''
new = '''        "PEPEW_BODY_PROFILE count=%zu samples=%llu total_cycles=%llu warm_load_cycles=%llu linear_accum_cycles=%llu sw_cycles=%llu cold_cycles=%llu reduce_cycles=%llu residual_cycles=%llu warm_cells=%llu cold_cells=%llu init_cycles=%llu row_cycles=%llu pair_outer_cycles=%llu row_unclassified_cycles=%llu outer_unclassified_cycles=%llu\\n",\n        count, profile_samples, profile_total, profile_warm, profile_linear, profile_sw, profile_cold, profile_reduce, profile_residual, profile_warm_cells, profile_cold_cells, profile_init, profile_row, profile_pair_outer,\n        profile_row > (profile_warm + profile_linear + profile_sw + profile_cold) ? profile_row - (profile_warm + profile_linear + profile_sw + profile_cold) : 0ULL,\n        profile_total > (profile_init + profile_row + profile_pair_outer) ? profile_total - (profile_init + profile_row + profile_pair_outer) : 0ULL);\n'''
if old not in p:
    raise SystemExit('report format anchor not found')
p = p.replace(old, new, 1)
part.write_text(p)
print('instrumented coarse residual decomposition on top of low-distortion body profiler')
