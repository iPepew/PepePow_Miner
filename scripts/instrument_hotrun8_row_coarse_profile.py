#!/usr/bin/env python3
from pathlib import Path

# Low-overhead sparse profiler for the dominant HotRun8 row budget.
# It deliberately avoids per-cell timers: one timer covers each full warm
# 8-cell batch segment and one timer covers the complete HooHash body.
# Exact arithmetic, state transitions, consensus and Stratum are untouched.

hot = Path('native/src/cuda/v1/header80_hotrun8.inc')
s = hot.read_text()

anchor = '''// Exact hot-run width-8 candidate. This file is included inside the anonymous
// CUDA namespace, before host methods. Consensus arithmetic is unchanged:
'''
insert = anchor + '''#if defined(PEPEPOW_CUDA_ROW_COARSE_PROFILE) && PEPEPOW_CUDA_ROW_COARSE_PROFILE
__device__ unsigned long long g_row_coarse_total_cycles = 0ULL;
__device__ unsigned long long g_row_coarse_warm_batch_cycles = 0ULL;
__device__ unsigned long long g_row_coarse_samples = 0ULL;
__device__ unsigned long long g_row_coarse_warm_batches = 0ULL;
#endif
'''
if anchor not in s:
    raise SystemExit('header anchor not found')
s = s.replace(anchor, insert, 1)

old_sig = '''    int row, const std::uint32_t first_pass[8], double hash_mod_fp64,
    double nonce_mod, HooHashSwState& sw) {'''
new_sig = '''    int row, const std::uint32_t first_pass[8], double hash_mod_fp64,
    double nonce_mod, HooHashSwState& sw, bool profile_sample,
    unsigned long long& lp_warm_batch, unsigned long long& lp_warm_batches) {'''
if old_sig not in s:
    raise SystemExit('matrix_row signature anchor not found')
s = s.replace(old_sig, new_sig, 1)

old_warm = '''        if (!sw_state_is_cold(sw) && col <= 56) {
            // Preserve an eight-cell logical hot run, but materialize only four
'''
new_warm = '''        if (!sw_state_is_cold(sw) && col <= 56) {
#if defined(PEPEPOW_CUDA_ROW_COARSE_PROFILE) && PEPEPOW_CUDA_ROW_COARSE_PROFILE
            const unsigned long long profile_warm_batch0 = profile_sample ? clock64() : 0ULL;
#endif
            // Preserve an eight-cell logical hot run, but materialize only four
'''
if old_warm not in s:
    raise SystemExit('warm branch anchor not found')
s = s.replace(old_warm, new_warm, 1)

old_end_warm = '''            col += consumed;
            continue;
'''
new_end_warm = '''#if defined(PEPEPOW_CUDA_ROW_COARSE_PROFILE) && PEPEPOW_CUDA_ROW_COARSE_PROFILE
            if (profile_sample) {
                lp_warm_batch += clock64() - profile_warm_batch0;
                ++lp_warm_batches;
            }
#endif
            col += consumed;
            continue;
'''
if old_end_warm not in s:
    raise SystemExit('warm branch end anchor not found')
s = s.replace(old_end_warm, new_end_warm, 1)

old_setup = '''    HooHashSwState sw = initial_sw_state();

    #pragma unroll 1
    for (int pair = 0; pair < 32; ++pair) {'''
new_setup = '''    HooHashSwState sw = initial_sw_state();
#if defined(PEPEPOW_CUDA_ROW_COARSE_PROFILE) && PEPEPOW_CUDA_ROW_COARSE_PROFILE
    const bool profile_sample = (first_pass[0] & 0x0fffU) == 0U;
    const unsigned long long profile_total0 = profile_sample ? clock64() : 0ULL;
    unsigned long long lp_warm_batch = 0ULL;
    unsigned long long lp_warm_batches = 0ULL;
#else
    const bool profile_sample = false;
    unsigned long long lp_warm_batch = 0ULL;
    unsigned long long lp_warm_batches = 0ULL;
#endif

    #pragma unroll 1
    for (int pair = 0; pair < 32; ++pair) {'''
if old_setup not in s:
    raise SystemExit('mix setup anchor not found')
s = s.replace(old_setup, new_setup, 1)

old_call = '''            hash_mod_fp64, nonce_mod, sw);'''
new_call = '''            hash_mod_fp64, nonce_mod, sw, profile_sample,
            lp_warm_batch, lp_warm_batches);'''
if s.count(old_call) != 2:
    raise SystemExit(f'expected 2 row calls, got {s.count(old_call)}')
s = s.replace(old_call, new_call, 2)

old_tail = '''        mixed[pair >> 2] ^=
            static_cast<std::uint32_t>(combined & 0xffU) << shift;
    }
}
'''
new_tail = '''        mixed[pair >> 2] ^=
            static_cast<std::uint32_t>(combined & 0xffU) << shift;
    }
#if defined(PEPEPOW_CUDA_ROW_COARSE_PROFILE) && PEPEPOW_CUDA_ROW_COARSE_PROFILE
    if (profile_sample) {
        atomicAdd(&g_row_coarse_warm_batch_cycles, lp_warm_batch);
        atomicAdd(&g_row_coarse_warm_batches, lp_warm_batches);
        atomicAdd(&g_row_coarse_total_cycles, clock64() - profile_total0);
        atomicAdd(&g_row_coarse_samples, 1ULL);
    }
#endif
}
'''
if old_tail not in s:
    raise SystemExit('mix tail anchor not found')
s = s.replace(old_tail, new_tail, 1)
hot.write_text(s)

part = Path('native/src/cuda/v1/header80_backend_part07.inc')
p = part.read_text()

reset_anchor = '''    constexpr unsigned int threads = static_cast<unsigned int>(PEPEPOW_CUDA_THREADS);
    const unsigned int blocks = static_cast<unsigned int>((count + threads - 1U) / threads);
'''
reset = reset_anchor + '''
#if defined(PEPEPOW_CUDA_ROW_COARSE_PROFILE) && PEPEPOW_CUDA_ROW_COARSE_PROFILE
    const unsigned long long row_profile_zero = 0ULL;
    check_cuda_header80(cudaMemcpyToSymbol(g_row_coarse_total_cycles, &row_profile_zero, sizeof(row_profile_zero)), "reset row coarse total");
    check_cuda_header80(cudaMemcpyToSymbol(g_row_coarse_warm_batch_cycles, &row_profile_zero, sizeof(row_profile_zero)), "reset row coarse warm batch");
    check_cuda_header80(cudaMemcpyToSymbol(g_row_coarse_samples, &row_profile_zero, sizeof(row_profile_zero)), "reset row coarse samples");
    check_cuda_header80(cudaMemcpyToSymbol(g_row_coarse_warm_batches, &row_profile_zero, sizeof(row_profile_zero)), "reset row coarse warm batches");
#endif
'''
if reset_anchor not in p:
    raise SystemExit('host reset anchor not found')
p = p.replace(reset_anchor, reset, 1)

report_anchor = '''    DeviceShareResult host_result{};
'''
report = '''#if defined(PEPEPOW_CUDA_ROW_COARSE_PROFILE) && PEPEPOW_CUDA_ROW_COARSE_PROFILE
    unsigned long long row_total=0, row_warm_batch=0, row_samples=0, row_warm_batches=0;
    check_cuda_header80(cudaMemcpyFromSymbol(&row_total, g_row_coarse_total_cycles, sizeof(row_total)), "copy row coarse total");
    check_cuda_header80(cudaMemcpyFromSymbol(&row_warm_batch, g_row_coarse_warm_batch_cycles, sizeof(row_warm_batch)), "copy row coarse warm batch");
    check_cuda_header80(cudaMemcpyFromSymbol(&row_samples, g_row_coarse_samples, sizeof(row_samples)), "copy row coarse samples");
    check_cuda_header80(cudaMemcpyFromSymbol(&row_warm_batches, g_row_coarse_warm_batches, sizeof(row_warm_batches)), "copy row coarse warm batches");
    const unsigned long long row_other = row_total > row_warm_batch ? row_total - row_warm_batch : 0ULL;
    std::fprintf(stderr,
        "PEPEW_ROW_COARSE_PROFILE count=%zu samples=%llu total_cycles=%llu warm_batch_cycles=%llu other_cycles=%llu warm_batches=%llu\\n",
        count, row_samples, row_total, row_warm_batch, row_other, row_warm_batches);
#endif

    DeviceShareResult host_result{};
'''
if report_anchor not in p:
    raise SystemExit('host report anchor not found')
p = p.replace(report_anchor, report, 1)
part.write_text(p)
print('instrumented low-overhead sparse HotRun8 row coarse profile')
