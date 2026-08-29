#!/usr/bin/env python3
from pathlib import Path

hot = Path('native/src/cuda/v1/header80_hotrun8.inc')
s = hot.read_text()
anchor = '''// Exact hot-run width-8 candidate. This file is included inside the anonymous
// CUDA namespace, before host methods. Consensus arithmetic is unchanged:
'''
insert = '''// Exact hot-run width-8 candidate. This file is included inside the anonymous
// CUDA namespace, before host methods. Consensus arithmetic is unchanged:
#if defined(PEPEPOW_CUDA_BODY_PROFILE) && PEPEPOW_CUDA_BODY_PROFILE
__device__ unsigned long long g_body_profile_total_cycles = 0ULL;
__device__ unsigned long long g_body_profile_warm_load_cycles = 0ULL;
__device__ unsigned long long g_body_profile_linear_accum_cycles = 0ULL;
__device__ unsigned long long g_body_profile_sw_cycles = 0ULL;
__device__ unsigned long long g_body_profile_cold_cycles = 0ULL;
__device__ unsigned long long g_body_profile_reduce_cycles = 0ULL;
__device__ unsigned long long g_body_profile_samples = 0ULL;
__device__ unsigned long long g_body_profile_warm_cells = 0ULL;
__device__ unsigned long long g_body_profile_cold_cells = 0ULL;
#endif
'''
if anchor not in s:
    raise SystemExit('hotrun8 header anchor not found')
s = s.replace(anchor, insert, 1)

s = s.replace(
'''    int row, const std::uint32_t first_pass[8], double hash_mod_fp64,
    double nonce_mod, HooHashSwState& sw) {''',
'''    int row, const std::uint32_t first_pass[8], double hash_mod_fp64,
    double nonce_mod, HooHashSwState& sw, bool profile_sample) {''', 1)

old_warm = '''                    contribution[i] = hotrun8_warm_contribution(
                        matrix, scaled_nibble_table, cell, nibble);
'''
new_warm = '''#if defined(PEPEPOW_CUDA_BODY_PROFILE) && PEPEPOW_CUDA_BODY_PROFILE
                    const unsigned long long profile_t0 = profile_sample ? clock64() : 0ULL;
#endif
                    contribution[i] = hotrun8_warm_contribution(
                        matrix, scaled_nibble_table, cell, nibble);
#if defined(PEPEPOW_CUDA_BODY_PROFILE) && PEPEPOW_CUDA_BODY_PROFILE
                    if (profile_sample) {
                        atomicAdd(&g_body_profile_warm_load_cycles, clock64() - profile_t0);
                        atomicAdd(&g_body_profile_warm_cells, 1ULL);
                    }
#endif
'''
if old_warm not in s:
    raise SystemExit('warm contribution anchor not found')
s = s.replace(old_warm, new_warm, 1)

old_commit = '''                    sum += contribution[i];
                    update_sw_state(sw, sum);
'''
new_commit = '''#if defined(PEPEPOW_CUDA_BODY_PROFILE) && PEPEPOW_CUDA_BODY_PROFILE
                    const unsigned long long profile_acc0 = profile_sample ? clock64() : 0ULL;
#endif
                    sum += contribution[i];
#if defined(PEPEPOW_CUDA_BODY_PROFILE) && PEPEPOW_CUDA_BODY_PROFILE
                    if (profile_sample) atomicAdd(&g_body_profile_linear_accum_cycles, clock64() - profile_acc0);
                    const unsigned long long profile_sw0 = profile_sample ? clock64() : 0ULL;
#endif
                    update_sw_state(sw, sum);
#if defined(PEPEPOW_CUDA_BODY_PROFILE) && PEPEPOW_CUDA_BODY_PROFILE
                    if (profile_sample) atomicAdd(&g_body_profile_sw_cycles, clock64() - profile_sw0);
#endif
'''
if old_commit not in s:
    raise SystemExit('warm commit anchor not found')
s = s.replace(old_commit, new_commit, 1)

old_cold = '''        if (sw_state_is_cold(sw)) {
            if (nibble != 0U) {
                const double value = nibble_to_double(nibble);
                const double x = matrix[cell] * hash_mod_fp64 * value + nonce_mod;
                sum += safe_nonlinear(x) * value * 1234.0;
            }
        } else {
            sum += hotrun8_warm_contribution(
                matrix, scaled_nibble_table, cell, nibble);
        }
        update_sw_state(sw, sum);
'''
new_cold = '''        if (sw_state_is_cold(sw)) {
#if defined(PEPEPOW_CUDA_BODY_PROFILE) && PEPEPOW_CUDA_BODY_PROFILE
            const unsigned long long profile_cold0 = profile_sample ? clock64() : 0ULL;
#endif
            if (nibble != 0U) {
                const double value = nibble_to_double(nibble);
                const double x = matrix[cell] * hash_mod_fp64 * value + nonce_mod;
                sum += safe_nonlinear(x) * value * 1234.0;
            }
#if defined(PEPEPOW_CUDA_BODY_PROFILE) && PEPEPOW_CUDA_BODY_PROFILE
            if (profile_sample) {
                atomicAdd(&g_body_profile_cold_cycles, clock64() - profile_cold0);
                atomicAdd(&g_body_profile_cold_cells, 1ULL);
            }
#endif
        } else {
#if defined(PEPEPOW_CUDA_BODY_PROFILE) && PEPEPOW_CUDA_BODY_PROFILE
            const unsigned long long profile_linear0 = profile_sample ? clock64() : 0ULL;
#endif
            sum += hotrun8_warm_contribution(
                matrix, scaled_nibble_table, cell, nibble);
#if defined(PEPEPOW_CUDA_BODY_PROFILE) && PEPEPOW_CUDA_BODY_PROFILE
            if (profile_sample) {
                atomicAdd(&g_body_profile_linear_accum_cycles, clock64() - profile_linear0);
                atomicAdd(&g_body_profile_warm_cells, 1ULL);
            }
#endif
        }
#if defined(PEPEPOW_CUDA_BODY_PROFILE) && PEPEPOW_CUDA_BODY_PROFILE
        const unsigned long long profile_sw1 = profile_sample ? clock64() : 0ULL;
#endif
        update_sw_state(sw, sum);
#if defined(PEPEPOW_CUDA_BODY_PROFILE) && PEPEPOW_CUDA_BODY_PROFILE
        if (profile_sample) atomicAdd(&g_body_profile_sw_cycles, clock64() - profile_sw1);
#endif
'''
if old_cold not in s:
    raise SystemExit('cold/linear anchor not found')
s = s.replace(old_cold, new_cold, 1)

old_setup = '''    HooHashSwState sw = initial_sw_state();

    #pragma unroll 1
    for (int pair = 0; pair < 32; ++pair) {'''
new_setup = '''    HooHashSwState sw = initial_sw_state();
#if defined(PEPEPOW_CUDA_BODY_PROFILE) && PEPEPOW_CUDA_BODY_PROFILE
    const bool profile_sample = (first_pass[0] & 0x0fffU) == 0U;
    const unsigned long long profile_total0 = profile_sample ? clock64() : 0ULL;
#else
    const bool profile_sample = false;
#endif

    #pragma unroll 1
    for (int pair = 0; pair < 32; ++pair) {'''
if old_setup not in s:
    raise SystemExit('mix setup anchor not found')
s = s.replace(old_setup, new_setup, 1)

s = s.replace('''            hash_mod_fp64, nonce_mod, sw);''', '''            hash_mod_fp64, nonce_mod, sw, profile_sample);''', 2)

old_reduce = '''        const std::uint64_t combined =
            positive_double_to_u64_rz(even_sum) +
            positive_double_to_u64_rz(odd_sum);
        const std::uint32_t shift = static_cast<std::uint32_t>((pair & 3) * 8);
        mixed[pair >> 2] ^=
            static_cast<std::uint32_t>(combined & 0xffU) << shift;
    }
}
'''
new_reduce = '''#if defined(PEPEPOW_CUDA_BODY_PROFILE) && PEPEPOW_CUDA_BODY_PROFILE
        const unsigned long long profile_reduce0 = profile_sample ? clock64() : 0ULL;
#endif
        const std::uint64_t combined =
            positive_double_to_u64_rz(even_sum) +
            positive_double_to_u64_rz(odd_sum);
        const std::uint32_t shift = static_cast<std::uint32_t>((pair & 3) * 8);
        mixed[pair >> 2] ^=
            static_cast<std::uint32_t>(combined & 0xffU) << shift;
#if defined(PEPEPOW_CUDA_BODY_PROFILE) && PEPEPOW_CUDA_BODY_PROFILE
        if (profile_sample) atomicAdd(&g_body_profile_reduce_cycles, clock64() - profile_reduce0);
#endif
    }
#if defined(PEPEPOW_CUDA_BODY_PROFILE) && PEPEPOW_CUDA_BODY_PROFILE
    if (profile_sample) {
        atomicAdd(&g_body_profile_total_cycles, clock64() - profile_total0);
        atomicAdd(&g_body_profile_samples, 1ULL);
    }
#endif
}
'''
if old_reduce not in s:
    raise SystemExit('pair reduction anchor not found')
s = s.replace(old_reduce, new_reduce, 1)
hot.write_text(s)

part = Path('native/src/cuda/v1/header80_backend_part07.inc')
p = part.read_text()
reset_anchor = '''    constexpr unsigned int threads = static_cast<unsigned int>(PEPEPOW_CUDA_THREADS);
    const unsigned int blocks = static_cast<unsigned int>((count + threads - 1U) / threads);
'''
reset = reset_anchor + '''
#if defined(PEPEPOW_CUDA_BODY_PROFILE) && PEPEPOW_CUDA_BODY_PROFILE
    const unsigned long long profile_zero = 0ULL;
    check_cuda_header80(cudaMemcpyToSymbol(g_body_profile_total_cycles, &profile_zero, sizeof(profile_zero)), "reset body total");
    check_cuda_header80(cudaMemcpyToSymbol(g_body_profile_warm_load_cycles, &profile_zero, sizeof(profile_zero)), "reset body warm load");
    check_cuda_header80(cudaMemcpyToSymbol(g_body_profile_linear_accum_cycles, &profile_zero, sizeof(profile_zero)), "reset body linear accum");
    check_cuda_header80(cudaMemcpyToSymbol(g_body_profile_sw_cycles, &profile_zero, sizeof(profile_zero)), "reset body sw");
    check_cuda_header80(cudaMemcpyToSymbol(g_body_profile_cold_cycles, &profile_zero, sizeof(profile_zero)), "reset body cold");
    check_cuda_header80(cudaMemcpyToSymbol(g_body_profile_reduce_cycles, &profile_zero, sizeof(profile_zero)), "reset body reduce");
    check_cuda_header80(cudaMemcpyToSymbol(g_body_profile_samples, &profile_zero, sizeof(profile_zero)), "reset body samples");
    check_cuda_header80(cudaMemcpyToSymbol(g_body_profile_warm_cells, &profile_zero, sizeof(profile_zero)), "reset body warm cells");
    check_cuda_header80(cudaMemcpyToSymbol(g_body_profile_cold_cells, &profile_zero, sizeof(profile_zero)), "reset body cold cells");
#endif
'''
if reset_anchor not in p:
    raise SystemExit('host reset anchor not found')
p = p.replace(reset_anchor, reset, 1)

report_anchor = '''    DeviceShareResult host_result{};
'''
report = '''#if defined(PEPEPOW_CUDA_BODY_PROFILE) && PEPEPOW_CUDA_BODY_PROFILE
    unsigned long long profile_total=0, profile_warm=0, profile_linear=0, profile_sw=0, profile_cold=0, profile_reduce=0, profile_samples=0, profile_warm_cells=0, profile_cold_cells=0;
    check_cuda_header80(cudaMemcpyFromSymbol(&profile_total, g_body_profile_total_cycles, sizeof(profile_total)), "copy body total");
    check_cuda_header80(cudaMemcpyFromSymbol(&profile_warm, g_body_profile_warm_load_cycles, sizeof(profile_warm)), "copy body warm");
    check_cuda_header80(cudaMemcpyFromSymbol(&profile_linear, g_body_profile_linear_accum_cycles, sizeof(profile_linear)), "copy body linear");
    check_cuda_header80(cudaMemcpyFromSymbol(&profile_sw, g_body_profile_sw_cycles, sizeof(profile_sw)), "copy body sw");
    check_cuda_header80(cudaMemcpyFromSymbol(&profile_cold, g_body_profile_cold_cycles, sizeof(profile_cold)), "copy body cold");
    check_cuda_header80(cudaMemcpyFromSymbol(&profile_reduce, g_body_profile_reduce_cycles, sizeof(profile_reduce)), "copy body reduce");
    check_cuda_header80(cudaMemcpyFromSymbol(&profile_samples, g_body_profile_samples, sizeof(profile_samples)), "copy body samples");
    check_cuda_header80(cudaMemcpyFromSymbol(&profile_warm_cells, g_body_profile_warm_cells, sizeof(profile_warm_cells)), "copy body warm cells");
    check_cuda_header80(cudaMemcpyFromSymbol(&profile_cold_cells, g_body_profile_cold_cells, sizeof(profile_cold_cells)), "copy body cold cells");
    const unsigned long long profile_measured = profile_warm + profile_linear + profile_sw + profile_cold + profile_reduce;
    const unsigned long long profile_residual = profile_total > profile_measured ? profile_total - profile_measured : 0ULL;
    std::fprintf(stderr,
        "PEPEW_BODY_PROFILE count=%zu samples=%llu total_cycles=%llu warm_load_cycles=%llu linear_accum_cycles=%llu sw_cycles=%llu cold_cycles=%llu reduce_cycles=%llu residual_cycles=%llu warm_cells=%llu cold_cells=%llu\\n",
        count, profile_samples, profile_total, profile_warm, profile_linear, profile_sw, profile_cold, profile_reduce, profile_residual, profile_warm_cells, profile_cold_cells);
#endif

    DeviceShareResult host_result{};
'''
if report_anchor not in p:
    raise SystemExit('host report anchor not found')
p = p.replace(report_anchor, report, 1)
part.write_text(p)
print('instrumented sparse HooHash body profile')
