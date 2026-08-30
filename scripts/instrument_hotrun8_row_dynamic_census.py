#!/usr/bin/env python3
from pathlib import Path
import runpy

# Build on the already validated sparse row-detail profiler.  The additional
# counters time the four dynamic mechanisms left inside its 57.2148% residual:
# first_pass nibble/address generation, warm table access, sw/control updates,
# and pair-end conversion.  Exact arithmetic and transition order are kept.
# All counters stay thread-local until one flush per sampled nonce.
runpy.run_path('scripts/instrument_hotrun8_row_detail_profile.py', run_name='__main__')

hot = Path('native/src/cuda/v1/header80_hotrun8.inc')
s = hot.read_text()

globals_anchor = '''__device__ unsigned long long g_row_detail_scalar_warm_cells = 0ULL;
#endif
'''
globals_new = '''__device__ unsigned long long g_row_detail_scalar_warm_cells = 0ULL;
__device__ unsigned long long g_row_dynamic_decode_address_cycles = 0ULL;
__device__ unsigned long long g_row_dynamic_warm_load_cycles = 0ULL;
__device__ unsigned long long g_row_dynamic_sw_control_cycles = 0ULL;
__device__ unsigned long long g_row_dynamic_pair_convert_cycles = 0ULL;
__device__ unsigned long long g_row_dynamic_timer_overhead_cycles = 0ULL;
__device__ unsigned long long g_row_dynamic_timer_events = 0ULL;
#endif
'''
if globals_anchor not in s:
    raise SystemExit('row-detail globals anchor not found')
s = s.replace(globals_anchor, globals_new, 1)

matrix_anchor = '''__device__ __forceinline__ double matrix_row_hotrun8(
'''
helpers = '''__device__ __forceinline__ std::uint32_t hotrun8_nibble_dynamic_profile(
    const std::uint32_t first_pass[8], int col, bool profile_sample,
    unsigned long long& lp_decode_address,
    unsigned long long& lp_timer_overhead,
    unsigned long long& lp_timer_events) {
    if (!profile_sample) return hotrun8_nibble(first_pass, col);
    const unsigned long long overhead0 = clock64();
    const unsigned long long overhead1 = clock64();
    const unsigned long long t0 = clock64();
    const std::uint32_t nibble = hotrun8_nibble(first_pass, col);
    const unsigned long long t1 = clock64();
    lp_timer_overhead += overhead1 - overhead0;
    lp_decode_address += t1 - t0;
    ++lp_timer_events;
    return nibble;
}

__device__ __forceinline__ double hotrun8_warm_dynamic_profile(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    int cell_index, std::uint32_t nibble, bool profile_sample,
    unsigned long long& lp_warm_load,
    unsigned long long& lp_timer_overhead,
    unsigned long long& lp_timer_events) {
    if (!profile_sample) {
        return hotrun8_warm_contribution(
            matrix, scaled_nibble_table, cell_index, nibble);
    }
    const unsigned long long overhead0 = clock64();
    const unsigned long long overhead1 = clock64();
    const unsigned long long t0 = clock64();
    const double value = hotrun8_warm_contribution(
        matrix, scaled_nibble_table, cell_index, nibble);
    const unsigned long long t1 = clock64();
    lp_timer_overhead += overhead1 - overhead0;
    lp_warm_load += t1 - t0;
    ++lp_timer_events;
    return value;
}

__device__ __forceinline__ void hotrun8_sw_dynamic_profile(
    HooHashSwState& sw, double sum, bool profile_sample,
    unsigned long long& lp_sw_control,
    unsigned long long& lp_timer_overhead,
    unsigned long long& lp_timer_events) {
    if (!profile_sample) {
        update_sw_state(sw, sum);
        return;
    }
    const unsigned long long overhead0 = clock64();
    const unsigned long long overhead1 = clock64();
    const unsigned long long t0 = clock64();
    update_sw_state(sw, sum);
    const bool cold_after = sw_state_is_cold(sw);
    const unsigned long long t1 = clock64();
    lp_timer_overhead += overhead1 - overhead0;
    lp_sw_control += t1 - t0;
    ++lp_timer_events;
    // Keep the predicate observable without changing the state machine.
    if (cold_after) asm volatile("" ::: "memory");
}

'''
if matrix_anchor not in s:
    raise SystemExit('matrix function anchor not found')
s = s.replace(matrix_anchor, helpers + matrix_anchor, 1)

sig_anchor = '''    unsigned long long& lp_scalar_cold_cells,
    unsigned long long& lp_scalar_warm_cells) {'''
sig_new = '''    unsigned long long& lp_scalar_cold_cells,
    unsigned long long& lp_scalar_warm_cells,
    unsigned long long& lp_decode_address,
    unsigned long long& lp_warm_load,
    unsigned long long& lp_sw_control,
    unsigned long long& lp_timer_overhead,
    unsigned long long& lp_timer_events) {'''
if sig_anchor not in s:
    raise SystemExit('instrumented matrix signature anchor not found')
s = s.replace(sig_anchor, sig_new, 1)

prefix, matrix_body = s.split(matrix_anchor, 1)
matrix_body = matrix_body.replace(
    'hotrun8_nibble(first_pass, col + offset);',
    'hotrun8_nibble_dynamic_profile(first_pass, col + offset, profile_sample,\n'
    '                        lp_decode_address, lp_timer_overhead, lp_timer_events);', 1)
matrix_body = matrix_body.replace(
    'hotrun8_nibble(first_pass, col);',
    'hotrun8_nibble_dynamic_profile(first_pass, col, profile_sample,\n'
    '            lp_decode_address, lp_timer_overhead, lp_timer_events);', 1)

warm_call = '''hotrun8_warm_contribution(
                        matrix, scaled_nibble_table, cell, nibble);'''
warm_call_new = '''hotrun8_warm_dynamic_profile(
                        matrix, scaled_nibble_table, cell, nibble, profile_sample,
                        lp_warm_load, lp_timer_overhead, lp_timer_events);'''
if warm_call not in matrix_body:
    raise SystemExit('warm batch call anchor not found')
matrix_body = matrix_body.replace(warm_call, warm_call_new, 1)

warm_scalar = '''hotrun8_warm_contribution(
                matrix, scaled_nibble_table, cell, nibble);'''
warm_scalar_new = '''hotrun8_warm_dynamic_profile(
                matrix, scaled_nibble_table, cell, nibble, profile_sample,
                lp_warm_load, lp_timer_overhead, lp_timer_events);'''
if warm_scalar not in matrix_body:
    raise SystemExit('warm scalar call anchor not found')
matrix_body = matrix_body.replace(warm_scalar, warm_scalar_new, 1)

sw_call = 'update_sw_state(sw, sum);'
sw_new = '''hotrun8_sw_dynamic_profile(
                        sw, sum, profile_sample, lp_sw_control,
                        lp_timer_overhead, lp_timer_events);'''
if matrix_body.count(sw_call) < 2:
    raise SystemExit('expected matrix sw calls')
matrix_body = matrix_body.replace(sw_call, sw_new, 1)
sw_new_scalar = '''hotrun8_sw_dynamic_profile(
            sw, sum, profile_sample, lp_sw_control,
            lp_timer_overhead, lp_timer_events);'''
matrix_body = matrix_body.replace(sw_call, sw_new_scalar, 1)
s = prefix + matrix_anchor + matrix_body

locals_anchor = '''    unsigned long long lp_scalar_warm_cells = 0ULL;
#else
'''
locals_new = '''    unsigned long long lp_scalar_warm_cells = 0ULL;
    unsigned long long lp_decode_address = 0ULL;
    unsigned long long lp_warm_load = 0ULL;
    unsigned long long lp_sw_control = 0ULL;
    unsigned long long lp_pair_convert = 0ULL;
    unsigned long long lp_timer_overhead = 0ULL;
    unsigned long long lp_timer_events = 0ULL;
#else
'''
if locals_anchor not in s:
    raise SystemExit('profile locals anchor not found')
s = s.replace(locals_anchor, locals_new, 1)

fallback_anchor = '''    unsigned long long lp_warm_groups = 0ULL, lp_scalar_cold_cells = 0ULL, lp_scalar_warm_cells = 0ULL;
#endif
'''
fallback_new = '''    unsigned long long lp_warm_groups = 0ULL, lp_scalar_cold_cells = 0ULL, lp_scalar_warm_cells = 0ULL;
    unsigned long long lp_decode_address = 0ULL, lp_warm_load = 0ULL, lp_sw_control = 0ULL;
    unsigned long long lp_pair_convert = 0ULL, lp_timer_overhead = 0ULL, lp_timer_events = 0ULL;
#endif
'''
if fallback_anchor not in s:
    raise SystemExit('profile fallback locals anchor not found')
s = s.replace(fallback_anchor, fallback_new, 1)

call_anchor = '''            lp_scalar_cold_cells, lp_scalar_warm_cells);'''
call_new = '''            lp_scalar_cold_cells, lp_scalar_warm_cells,
            lp_decode_address, lp_warm_load, lp_sw_control,
            lp_timer_overhead, lp_timer_events);'''
if s.count(call_anchor) != 2:
    raise SystemExit(f'expected two instrumented row calls, got {s.count(call_anchor)}')
s = s.replace(call_anchor, call_new, 2)

pair_anchor = '''        const std::uint64_t combined =
            positive_double_to_u64_rz(even_sum) +
            positive_double_to_u64_rz(odd_sum);'''
pair_new = '''#if defined(PEPEPOW_CUDA_ROW_DETAIL_PROFILE) && PEPEPOW_CUDA_ROW_DETAIL_PROFILE
        const unsigned long long pair_overhead0 = profile_sample ? clock64() : 0ULL;
        const unsigned long long pair_overhead1 = profile_sample ? clock64() : 0ULL;
        const unsigned long long pair0 = profile_sample ? clock64() : 0ULL;
#endif
        const std::uint64_t combined =
            positive_double_to_u64_rz(even_sum) +
            positive_double_to_u64_rz(odd_sum);
#if defined(PEPEPOW_CUDA_ROW_DETAIL_PROFILE) && PEPEPOW_CUDA_ROW_DETAIL_PROFILE
        if (profile_sample) {
            lp_pair_convert += clock64() - pair0;
            lp_timer_overhead += pair_overhead1 - pair_overhead0;
            ++lp_timer_events;
        }
#endif'''
if pair_anchor not in s:
    raise SystemExit('pair conversion anchor not found')
s = s.replace(pair_anchor, pair_new, 1)

flush_anchor = '''        atomicAdd(&g_row_detail_scalar_warm_cells, lp_scalar_warm_cells);
        atomicAdd(&g_row_detail_samples, 1ULL);'''
flush_new = '''        atomicAdd(&g_row_detail_scalar_warm_cells, lp_scalar_warm_cells);
        atomicAdd(&g_row_dynamic_decode_address_cycles, lp_decode_address);
        atomicAdd(&g_row_dynamic_warm_load_cycles, lp_warm_load);
        atomicAdd(&g_row_dynamic_sw_control_cycles, lp_sw_control);
        atomicAdd(&g_row_dynamic_pair_convert_cycles, lp_pair_convert);
        atomicAdd(&g_row_dynamic_timer_overhead_cycles, lp_timer_overhead);
        atomicAdd(&g_row_dynamic_timer_events, lp_timer_events);
        atomicAdd(&g_row_detail_samples, 1ULL);'''
if flush_anchor not in s:
    raise SystemExit('profile flush anchor not found')
s = s.replace(flush_anchor, flush_new, 1)
hot.write_text(s)

part = Path('native/src/cuda/v1/header80_backend_part07.inc')
p = part.read_text()
reset_anchor = '''    check_cuda_header80(cudaMemcpyToSymbol(g_row_detail_scalar_warm_cells, &row_detail_zero, sizeof(row_detail_zero)), "reset row detail scalar warm cells");
#endif'''
reset_new = '''    check_cuda_header80(cudaMemcpyToSymbol(g_row_detail_scalar_warm_cells, &row_detail_zero, sizeof(row_detail_zero)), "reset row detail scalar warm cells");
    check_cuda_header80(cudaMemcpyToSymbol(g_row_dynamic_decode_address_cycles, &row_detail_zero, sizeof(row_detail_zero)), "reset row dynamic decode/address");
    check_cuda_header80(cudaMemcpyToSymbol(g_row_dynamic_warm_load_cycles, &row_detail_zero, sizeof(row_detail_zero)), "reset row dynamic warm load");
    check_cuda_header80(cudaMemcpyToSymbol(g_row_dynamic_sw_control_cycles, &row_detail_zero, sizeof(row_detail_zero)), "reset row dynamic sw/control");
    check_cuda_header80(cudaMemcpyToSymbol(g_row_dynamic_pair_convert_cycles, &row_detail_zero, sizeof(row_detail_zero)), "reset row dynamic pair conversion");
    check_cuda_header80(cudaMemcpyToSymbol(g_row_dynamic_timer_overhead_cycles, &row_detail_zero, sizeof(row_detail_zero)), "reset row dynamic timer overhead");
    check_cuda_header80(cudaMemcpyToSymbol(g_row_dynamic_timer_events, &row_detail_zero, sizeof(row_detail_zero)), "reset row dynamic timer events");
#endif'''
if reset_anchor not in p:
    raise SystemExit('host reset extension anchor not found')
p = p.replace(reset_anchor, reset_new, 1)

report_anchor = '''    const unsigned long long rd_classified = rd_prepare + rd_commit + rd_cold + rd_warm;
'''
report_new = '''    unsigned long long dyn_decode=0, dyn_load=0, dyn_sw=0, dyn_pair=0, dyn_overhead=0, dyn_events=0;
    check_cuda_header80(cudaMemcpyFromSymbol(&dyn_decode, g_row_dynamic_decode_address_cycles, sizeof(dyn_decode)), "copy row dynamic decode/address");
    check_cuda_header80(cudaMemcpyFromSymbol(&dyn_load, g_row_dynamic_warm_load_cycles, sizeof(dyn_load)), "copy row dynamic warm load");
    check_cuda_header80(cudaMemcpyFromSymbol(&dyn_sw, g_row_dynamic_sw_control_cycles, sizeof(dyn_sw)), "copy row dynamic sw/control");
    check_cuda_header80(cudaMemcpyFromSymbol(&dyn_pair, g_row_dynamic_pair_convert_cycles, sizeof(dyn_pair)), "copy row dynamic pair conversion");
    check_cuda_header80(cudaMemcpyFromSymbol(&dyn_overhead, g_row_dynamic_timer_overhead_cycles, sizeof(dyn_overhead)), "copy row dynamic timer overhead");
    check_cuda_header80(cudaMemcpyFromSymbol(&dyn_events, g_row_dynamic_timer_events, sizeof(dyn_events)), "copy row dynamic timer events");
    std::fprintf(stderr,
        "PEPEW_ROW_DYNAMIC_CENSUS count=%zu samples=%llu row_total_cycles=%llu decode_address_cycles=%llu warm_load_cycles=%llu sw_control_cycles=%llu pair_convert_cycles=%llu timer_overhead_cycles=%llu timer_events=%llu\\n",
        count, rd_samples, rd_total, dyn_decode, dyn_load, dyn_sw, dyn_pair, dyn_overhead, dyn_events);
    const unsigned long long rd_classified = rd_prepare + rd_commit + rd_cold + rd_warm;
'''
if report_anchor not in p:
    raise SystemExit('host report extension anchor not found')
p = p.replace(report_anchor, report_new, 1)
part.write_text(p)
print('instrumented sparse HotRun8 row dynamic census')
