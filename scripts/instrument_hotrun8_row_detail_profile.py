#!/usr/bin/env python3
from pathlib import Path

# Sparse exact profiler for the dominant matrix-row budget.
# It decomposes a sampled row into warm contribution preparation, warm commit
# (sum + exact sw update), scalar cold work, scalar warm-tail work, and residual.
# No arithmetic, state transition, consensus rule, target rule or Stratum path
# is changed. Counters are thread-local and flushed once per sampled nonce.

hot = Path('native/src/cuda/v1/header80_hotrun8.inc')
s = hot.read_text()

anchor = '''// Exact hot-run width-8 candidate. This file is included inside the anonymous
// CUDA namespace, before host methods. Consensus arithmetic is unchanged:
'''
insert = anchor + '''#if defined(PEPEPOW_CUDA_ROW_DETAIL_PROFILE) && PEPEPOW_CUDA_ROW_DETAIL_PROFILE
__device__ unsigned long long g_row_detail_total_cycles = 0ULL;
__device__ unsigned long long g_row_detail_warm_prepare_cycles = 0ULL;
__device__ unsigned long long g_row_detail_warm_commit_cycles = 0ULL;
__device__ unsigned long long g_row_detail_scalar_cold_cycles = 0ULL;
__device__ unsigned long long g_row_detail_scalar_warm_cycles = 0ULL;
__device__ unsigned long long g_row_detail_samples = 0ULL;
__device__ unsigned long long g_row_detail_rows = 0ULL;
__device__ unsigned long long g_row_detail_warm_groups = 0ULL;
__device__ unsigned long long g_row_detail_scalar_cold_cells = 0ULL;
__device__ unsigned long long g_row_detail_scalar_warm_cells = 0ULL;
#endif
'''
if anchor not in s:
    raise SystemExit('header anchor not found')
s = s.replace(anchor, insert, 1)

old_sig = '''    int row, const std::uint32_t first_pass[8], double hash_mod_fp64,
    double nonce_mod, HooHashSwState& sw) {'''
new_sig = '''    int row, const std::uint32_t first_pass[8], double hash_mod_fp64,
    double nonce_mod, HooHashSwState& sw, bool profile_sample,
    unsigned long long& lp_row_total,
    unsigned long long& lp_warm_prepare,
    unsigned long long& lp_warm_commit,
    unsigned long long& lp_scalar_cold,
    unsigned long long& lp_scalar_warm,
    unsigned long long& lp_rows,
    unsigned long long& lp_warm_groups,
    unsigned long long& lp_scalar_cold_cells,
    unsigned long long& lp_scalar_warm_cells) {'''
if old_sig not in s:
    raise SystemExit('matrix_row signature anchor not found')
s = s.replace(old_sig, new_sig, 1)

row_start = '''    double sum = 0.0;
    const int row_offset = row * 64;

    #pragma unroll 1
'''
row_start_new = '''    double sum = 0.0;
    const int row_offset = row * 64;
#if defined(PEPEPOW_CUDA_ROW_DETAIL_PROFILE) && PEPEPOW_CUDA_ROW_DETAIL_PROFILE
    const unsigned long long profile_row0 = profile_sample ? clock64() : 0ULL;
#endif

    #pragma unroll 1
'''
if row_start not in s:
    raise SystemExit('row start anchor not found')
s = s.replace(row_start, row_start_new, 1)

prep_anchor = '''                double contribution[4];
                #pragma unroll
                for (int i = 0; i < 4; ++i) {'''
prep_new = '''                double contribution[4];
#if defined(PEPEPOW_CUDA_ROW_DETAIL_PROFILE) && PEPEPOW_CUDA_ROW_DETAIL_PROFILE
                const unsigned long long profile_prepare0 = profile_sample ? clock64() : 0ULL;
#endif
                #pragma unroll
                for (int i = 0; i < 4; ++i) {'''
if prep_anchor not in s:
    raise SystemExit('warm prepare anchor not found')
s = s.replace(prep_anchor, prep_new, 1)

commit_anchor = '''                }

                #pragma unroll
                for (int i = 0; i < 4; ++i) {
                    sum += contribution[i];'''
commit_new = '''                }
#if defined(PEPEPOW_CUDA_ROW_DETAIL_PROFILE) && PEPEPOW_CUDA_ROW_DETAIL_PROFILE
                const unsigned long long profile_prepare1 = profile_sample ? clock64() : 0ULL;
                const unsigned long long profile_commit0 = profile_sample ? clock64() : 0ULL;
#endif

                #pragma unroll
                for (int i = 0; i < 4; ++i) {
                    sum += contribution[i];'''
if commit_anchor not in s:
    raise SystemExit('warm commit anchor not found')
s = s.replace(commit_anchor, commit_new, 1)

commit_end = '''                    ++consumed;
                    if (sw_state_is_cold(sw)) break;
                }
                if (sw_state_is_cold(sw)) break;
'''
commit_end_new = '''                    ++consumed;
                    if (sw_state_is_cold(sw)) break;
                }
#if defined(PEPEPOW_CUDA_ROW_DETAIL_PROFILE) && PEPEPOW_CUDA_ROW_DETAIL_PROFILE
                if (profile_sample) {
                    lp_warm_prepare += profile_prepare1 - profile_prepare0;
                    lp_warm_commit += clock64() - profile_commit0;
                    ++lp_warm_groups;
                }
#endif
                if (sw_state_is_cold(sw)) break;
'''
if commit_end not in s:
    raise SystemExit('warm commit end anchor not found')
s = s.replace(commit_end, commit_end_new, 1)

scalar_anchor = '''        const int cell = row_offset + col;
        const std::uint32_t nibble = hotrun8_nibble(first_pass, col);
        if (sw_state_is_cold(sw)) {'''
scalar_new = '''        const int cell = row_offset + col;
        const std::uint32_t nibble = hotrun8_nibble(first_pass, col);
        const bool profile_scalar_cold = sw_state_is_cold(sw);
#if defined(PEPEPOW_CUDA_ROW_DETAIL_PROFILE) && PEPEPOW_CUDA_ROW_DETAIL_PROFILE
        const unsigned long long profile_scalar0 = profile_sample ? clock64() : 0ULL;
#endif
        if (profile_scalar_cold) {'''
if scalar_anchor not in s:
    raise SystemExit('scalar anchor not found')
s = s.replace(scalar_anchor, scalar_new, 1)

scalar_end = '''        update_sw_state(sw, sum);
        ++col;
    }
    return sum;
}'''
scalar_end_new = '''        update_sw_state(sw, sum);
#if defined(PEPEPOW_CUDA_ROW_DETAIL_PROFILE) && PEPEPOW_CUDA_ROW_DETAIL_PROFILE
        if (profile_sample) {
            const unsigned long long scalar_cycles = clock64() - profile_scalar0;
            if (profile_scalar_cold) {
                lp_scalar_cold += scalar_cycles;
                ++lp_scalar_cold_cells;
            } else {
                lp_scalar_warm += scalar_cycles;
                ++lp_scalar_warm_cells;
            }
        }
#endif
        ++col;
    }
#if defined(PEPEPOW_CUDA_ROW_DETAIL_PROFILE) && PEPEPOW_CUDA_ROW_DETAIL_PROFILE
    if (profile_sample) {
        lp_row_total += clock64() - profile_row0;
        ++lp_rows;
    }
#endif
    return sum;
}'''
if scalar_end not in s:
    raise SystemExit('scalar/row tail anchor not found')
s = s.replace(scalar_end, scalar_end_new, 1)

setup = '''    HooHashSwState sw = initial_sw_state();

    #pragma unroll 1
    for (int pair = 0; pair < 32; ++pair) {'''
setup_new = '''    HooHashSwState sw = initial_sw_state();
#if defined(PEPEPOW_CUDA_ROW_DETAIL_PROFILE) && PEPEPOW_CUDA_ROW_DETAIL_PROFILE
    const bool profile_sample = (first_pass[0] & 0x0fffU) == 0U;
    unsigned long long lp_row_total = 0ULL;
    unsigned long long lp_warm_prepare = 0ULL;
    unsigned long long lp_warm_commit = 0ULL;
    unsigned long long lp_scalar_cold = 0ULL;
    unsigned long long lp_scalar_warm = 0ULL;
    unsigned long long lp_rows = 0ULL;
    unsigned long long lp_warm_groups = 0ULL;
    unsigned long long lp_scalar_cold_cells = 0ULL;
    unsigned long long lp_scalar_warm_cells = 0ULL;
#else
    const bool profile_sample = false;
    unsigned long long lp_row_total = 0ULL, lp_warm_prepare = 0ULL, lp_warm_commit = 0ULL;
    unsigned long long lp_scalar_cold = 0ULL, lp_scalar_warm = 0ULL, lp_rows = 0ULL;
    unsigned long long lp_warm_groups = 0ULL, lp_scalar_cold_cells = 0ULL, lp_scalar_warm_cells = 0ULL;
#endif

    #pragma unroll 1
    for (int pair = 0; pair < 32; ++pair) {'''
if setup not in s:
    raise SystemExit('mix setup anchor not found')
s = s.replace(setup, setup_new, 1)

old_call = '''            hash_mod_fp64, nonce_mod, sw);'''
new_call = '''            hash_mod_fp64, nonce_mod, sw, profile_sample,
            lp_row_total, lp_warm_prepare, lp_warm_commit,
            lp_scalar_cold, lp_scalar_warm, lp_rows, lp_warm_groups,
            lp_scalar_cold_cells, lp_scalar_warm_cells);'''
if s.count(old_call) != 2:
    raise SystemExit(f'expected 2 row calls, got {s.count(old_call)}')
s = s.replace(old_call, new_call, 2)

mix_tail = '''        mixed[pair >> 2] ^=
            static_cast<std::uint32_t>(combined & 0xffU) << shift;
    }
}
'''
mix_tail_new = '''        mixed[pair >> 2] ^=
            static_cast<std::uint32_t>(combined & 0xffU) << shift;
    }
#if defined(PEPEPOW_CUDA_ROW_DETAIL_PROFILE) && PEPEPOW_CUDA_ROW_DETAIL_PROFILE
    if (profile_sample) {
        atomicAdd(&g_row_detail_total_cycles, lp_row_total);
        atomicAdd(&g_row_detail_warm_prepare_cycles, lp_warm_prepare);
        atomicAdd(&g_row_detail_warm_commit_cycles, lp_warm_commit);
        atomicAdd(&g_row_detail_scalar_cold_cycles, lp_scalar_cold);
        atomicAdd(&g_row_detail_scalar_warm_cycles, lp_scalar_warm);
        atomicAdd(&g_row_detail_rows, lp_rows);
        atomicAdd(&g_row_detail_warm_groups, lp_warm_groups);
        atomicAdd(&g_row_detail_scalar_cold_cells, lp_scalar_cold_cells);
        atomicAdd(&g_row_detail_scalar_warm_cells, lp_scalar_warm_cells);
        atomicAdd(&g_row_detail_samples, 1ULL);
    }
#endif
}
'''
if mix_tail not in s:
    raise SystemExit('mix tail anchor not found')
s = s.replace(mix_tail, mix_tail_new, 1)
hot.write_text(s)

part = Path('native/src/cuda/v1/header80_backend_part07.inc')
p = part.read_text()
reset_anchor = '''    constexpr unsigned int threads = static_cast<unsigned int>(PEPEPOW_CUDA_THREADS);
    const unsigned int blocks = static_cast<unsigned int>((count + threads - 1U) / threads);
'''
reset = reset_anchor + '''
#if defined(PEPEPOW_CUDA_ROW_DETAIL_PROFILE) && PEPEPOW_CUDA_ROW_DETAIL_PROFILE
    const unsigned long long row_detail_zero = 0ULL;
    check_cuda_header80(cudaMemcpyToSymbol(g_row_detail_total_cycles, &row_detail_zero, sizeof(row_detail_zero)), "reset row detail total");
    check_cuda_header80(cudaMemcpyToSymbol(g_row_detail_warm_prepare_cycles, &row_detail_zero, sizeof(row_detail_zero)), "reset row detail warm prepare");
    check_cuda_header80(cudaMemcpyToSymbol(g_row_detail_warm_commit_cycles, &row_detail_zero, sizeof(row_detail_zero)), "reset row detail warm commit");
    check_cuda_header80(cudaMemcpyToSymbol(g_row_detail_scalar_cold_cycles, &row_detail_zero, sizeof(row_detail_zero)), "reset row detail scalar cold");
    check_cuda_header80(cudaMemcpyToSymbol(g_row_detail_scalar_warm_cycles, &row_detail_zero, sizeof(row_detail_zero)), "reset row detail scalar warm");
    check_cuda_header80(cudaMemcpyToSymbol(g_row_detail_samples, &row_detail_zero, sizeof(row_detail_zero)), "reset row detail samples");
    check_cuda_header80(cudaMemcpyToSymbol(g_row_detail_rows, &row_detail_zero, sizeof(row_detail_zero)), "reset row detail rows");
    check_cuda_header80(cudaMemcpyToSymbol(g_row_detail_warm_groups, &row_detail_zero, sizeof(row_detail_zero)), "reset row detail warm groups");
    check_cuda_header80(cudaMemcpyToSymbol(g_row_detail_scalar_cold_cells, &row_detail_zero, sizeof(row_detail_zero)), "reset row detail scalar cold cells");
    check_cuda_header80(cudaMemcpyToSymbol(g_row_detail_scalar_warm_cells, &row_detail_zero, sizeof(row_detail_zero)), "reset row detail scalar warm cells");
#endif
'''
if reset_anchor not in p:
    raise SystemExit('host reset anchor not found')
p = p.replace(reset_anchor, reset, 1)

report_anchor = '''    DeviceShareResult host_result{};
'''
report = '''#if defined(PEPEPOW_CUDA_ROW_DETAIL_PROFILE) && PEPEPOW_CUDA_ROW_DETAIL_PROFILE
    unsigned long long rd_total=0, rd_prepare=0, rd_commit=0, rd_cold=0, rd_warm=0;
    unsigned long long rd_samples=0, rd_rows=0, rd_groups=0, rd_cold_cells=0, rd_warm_cells=0;
    check_cuda_header80(cudaMemcpyFromSymbol(&rd_total, g_row_detail_total_cycles, sizeof(rd_total)), "copy row detail total");
    check_cuda_header80(cudaMemcpyFromSymbol(&rd_prepare, g_row_detail_warm_prepare_cycles, sizeof(rd_prepare)), "copy row detail warm prepare");
    check_cuda_header80(cudaMemcpyFromSymbol(&rd_commit, g_row_detail_warm_commit_cycles, sizeof(rd_commit)), "copy row detail warm commit");
    check_cuda_header80(cudaMemcpyFromSymbol(&rd_cold, g_row_detail_scalar_cold_cycles, sizeof(rd_cold)), "copy row detail scalar cold");
    check_cuda_header80(cudaMemcpyFromSymbol(&rd_warm, g_row_detail_scalar_warm_cycles, sizeof(rd_warm)), "copy row detail scalar warm");
    check_cuda_header80(cudaMemcpyFromSymbol(&rd_samples, g_row_detail_samples, sizeof(rd_samples)), "copy row detail samples");
    check_cuda_header80(cudaMemcpyFromSymbol(&rd_rows, g_row_detail_rows, sizeof(rd_rows)), "copy row detail rows");
    check_cuda_header80(cudaMemcpyFromSymbol(&rd_groups, g_row_detail_warm_groups, sizeof(rd_groups)), "copy row detail warm groups");
    check_cuda_header80(cudaMemcpyFromSymbol(&rd_cold_cells, g_row_detail_scalar_cold_cells, sizeof(rd_cold_cells)), "copy row detail cold cells");
    check_cuda_header80(cudaMemcpyFromSymbol(&rd_warm_cells, g_row_detail_scalar_warm_cells, sizeof(rd_warm_cells)), "copy row detail warm cells");
    const unsigned long long rd_classified = rd_prepare + rd_commit + rd_cold + rd_warm;
    const unsigned long long rd_residual = rd_total > rd_classified ? rd_total - rd_classified : 0ULL;
    std::fprintf(stderr,
        "PEPEW_ROW_DETAIL_PROFILE count=%zu samples=%llu total_cycles=%llu warm_prepare_cycles=%llu warm_commit_cycles=%llu scalar_cold_cycles=%llu scalar_warm_cycles=%llu residual_cycles=%llu rows=%llu warm_groups=%llu scalar_cold_cells=%llu scalar_warm_cells=%llu\\n",
        count, rd_samples, rd_total, rd_prepare, rd_commit, rd_cold, rd_warm, rd_residual,
        rd_rows, rd_groups, rd_cold_cells, rd_warm_cells);
#endif

    DeviceShareResult host_result{};
'''
if report_anchor not in p:
    raise SystemExit('host report anchor not found')
p = p.replace(report_anchor, report, 1)
part.write_text(p)
print('instrumented low-distortion sparse HotRun8 row detail profile')
