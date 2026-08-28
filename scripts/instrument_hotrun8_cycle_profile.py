#!/usr/bin/env python3
from pathlib import Path

hot = Path('native/src/cuda/v1/header80_hotrun8.inc')
s = hot.read_text()

needle = '__device__ __forceinline__ std::uint32_t hotrun8_nibble('
prefix = '''#if defined(PEPEPOW_CUDA_HOOHASH_CYCLE_PROFILE) && PEPEPOW_CUDA_HOOHASH_CYCLE_PROFILE
__device__ unsigned long long g_hoohash_profile_total_cycles = 0ULL;
__device__ unsigned long long g_hoohash_profile_nonlinear_cycles = 0ULL;
__device__ unsigned long long g_hoohash_profile_nonlinear_calls = 0ULL;
__device__ unsigned long long g_hoohash_profile_samples = 0ULL;
#endif

'''
if needle not in s:
    raise SystemExit('hotrun8 nibble marker not found')
s = s.replace(needle, prefix + needle, 1)

old_sig = '''    int row, const std::uint32_t first_pass[8], double hash_mod_fp64,
    double nonce_mod, HooHashSwState& sw) {'''
new_sig = '''    int row, const std::uint32_t first_pass[8], double hash_mod_fp64,
    double nonce_mod, HooHashSwState& sw,
    unsigned long long& profile_nonlinear_cycles,
    unsigned long long& profile_nonlinear_calls) {'''
if old_sig not in s:
    raise SystemExit('matrix_row_hotrun8 signature marker not found')
s = s.replace(old_sig, new_sig, 1)

old_nl = '''                const double x = matrix[cell] * hash_mod_fp64 * value + nonce_mod;
                sum += safe_nonlinear(x) * value * 1234.0;'''
new_nl = '''                const double x = matrix[cell] * hash_mod_fp64 * value + nonce_mod;
#if defined(PEPEPOW_CUDA_HOOHASH_CYCLE_PROFILE) && PEPEPOW_CUDA_HOOHASH_CYCLE_PROFILE
                const bool profile_sample =
                    threadIdx.x == 0U && ((blockIdx.x & 63U) == 0U);
                unsigned long long profile_begin = 0ULL;
                if (profile_sample) profile_begin = clock64();
                const double nonlinear_value = safe_nonlinear(x);
                if (profile_sample) {
                    profile_nonlinear_cycles += clock64() - profile_begin;
                    ++profile_nonlinear_calls;
                }
                sum += nonlinear_value * value * 1234.0;
#else
                sum += safe_nonlinear(x) * value * 1234.0;
#endif'''
if old_nl not in s:
    raise SystemExit('safe_nonlinear call marker not found')
s = s.replace(old_nl, new_nl, 1)

old_state = '''    HooHashSwState sw = initial_sw_state();

    #pragma unroll 1
    for (int pair = 0; pair < 32; ++pair) {'''
new_state = '''    HooHashSwState sw = initial_sw_state();
    unsigned long long profile_nonlinear_cycles = 0ULL;
    unsigned long long profile_nonlinear_calls = 0ULL;
#if defined(PEPEPOW_CUDA_HOOHASH_CYCLE_PROFILE) && PEPEPOW_CUDA_HOOHASH_CYCLE_PROFILE
    const bool profile_sample =
        threadIdx.x == 0U && ((blockIdx.x & 63U) == 0U);
    const unsigned long long profile_hoohash_begin = profile_sample ? clock64() : 0ULL;
#endif

    #pragma unroll 1
    for (int pair = 0; pair < 32; ++pair) {'''
if old_state not in s:
    raise SystemExit('HooHash state marker not found')
s = s.replace(old_state, new_state, 1)

old_even = '''            matrix, scaled_nibble_table, pair * 2, first_pass,
            hash_mod_fp64, nonce_mod, sw);'''
new_even = '''            matrix, scaled_nibble_table, pair * 2, first_pass,
            hash_mod_fp64, nonce_mod, sw,
            profile_nonlinear_cycles, profile_nonlinear_calls);'''
if s.count(old_even) < 2:
    raise SystemExit('matrix_row_hotrun8 call markers not found')
s = s.replace(old_even, new_even, 1)
old_odd = '''            matrix, scaled_nibble_table, pair * 2 + 1, first_pass,
            hash_mod_fp64, nonce_mod, sw);'''
new_odd = '''            matrix, scaled_nibble_table, pair * 2 + 1, first_pass,
            hash_mod_fp64, nonce_mod, sw,
            profile_nonlinear_cycles, profile_nonlinear_calls);'''
if old_odd not in s:
    raise SystemExit('odd matrix_row_hotrun8 call marker not found')
s = s.replace(old_odd, new_odd, 1)

old_end = '''        mixed[pair >> 2] ^=
            static_cast<std::uint32_t>(combined & 0xffU) << shift;
    }
}

// Split middle-stage probe/candidate.'''
new_end = '''        mixed[pair >> 2] ^=
            static_cast<std::uint32_t>(combined & 0xffU) << shift;
    }
#if defined(PEPEPOW_CUDA_HOOHASH_CYCLE_PROFILE) && PEPEPOW_CUDA_HOOHASH_CYCLE_PROFILE
    if (profile_sample) {
        const unsigned long long profile_total_cycles =
            clock64() - profile_hoohash_begin;
        atomicAdd(&g_hoohash_profile_total_cycles, profile_total_cycles);
        atomicAdd(&g_hoohash_profile_nonlinear_cycles, profile_nonlinear_cycles);
        atomicAdd(&g_hoohash_profile_nonlinear_calls, profile_nonlinear_calls);
        atomicAdd(&g_hoohash_profile_samples, 1ULL);
    }
#endif
}

// Split middle-stage probe/candidate.'''
if old_end not in s:
    raise SystemExit('hoohash_mix_words_hotrun8 end marker not found')
s = s.replace(old_end, new_end, 1)
hot.write_text(s)

part = Path('native/src/cuda/v1/header80_backend_part07.inc')
p = part.read_text()
launch_marker = '''    header80_first_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin), work_words, count);'''
reset = '''#if defined(PEPEPOW_CUDA_HOOHASH_CYCLE_PROFILE) && PEPEPOW_CUDA_HOOHASH_CYCLE_PROFILE
    const unsigned long long profile_zero = 0ULL;
    check_cuda_header80(cudaMemcpyToSymbol(g_hoohash_profile_total_cycles, &profile_zero, sizeof(profile_zero)), "reset HooHash total cycles");
    check_cuda_header80(cudaMemcpyToSymbol(g_hoohash_profile_nonlinear_cycles, &profile_zero, sizeof(profile_zero)), "reset HooHash nonlinear cycles");
    check_cuda_header80(cudaMemcpyToSymbol(g_hoohash_profile_nonlinear_calls, &profile_zero, sizeof(profile_zero)), "reset HooHash nonlinear calls");
    check_cuda_header80(cudaMemcpyToSymbol(g_hoohash_profile_samples, &profile_zero, sizeof(profile_zero)), "reset HooHash samples");
#endif
'''
# Insert only in fusion2 branch, identified by the immediately preceding stage-profile block.
fusion_anchor = '''#elif defined(PEPEPOW_CUDA_HOTRUN8) && PEPEPOW_CUDA_HOTRUN8 && defined(PEPEPOW_CUDA_HOTRUN8_FUSION_MODE) && PEPEPOW_CUDA_HOTRUN8_FUSION_MODE == 2
#if defined(PEPEPOW_CUDA_STAGE_PROFILE) && PEPEPOW_CUDA_STAGE_PROFILE'''
idx = p.find(fusion_anchor)
if idx < 0:
    raise SystemExit('fusion2 branch marker not found')
launch_idx = p.find(launch_marker, idx)
if launch_idx < 0:
    raise SystemExit('fusion2 first-kernel launch marker not found')
p = p[:launch_idx] + reset + p[launch_idx:]

fused_check = '''    check_cuda_header80(cudaGetLastError(), "hoohash_final_hotrun8_fused_kernel launch");'''
readback = '''
#if defined(PEPEPOW_CUDA_HOOHASH_CYCLE_PROFILE) && PEPEPOW_CUDA_HOOHASH_CYCLE_PROFILE
    check_cuda_header80(cudaDeviceSynchronize(), "cudaDeviceSynchronize(HooHash cycle profile)");
    unsigned long long profile_total_cycles = 0ULL;
    unsigned long long profile_nonlinear_cycles = 0ULL;
    unsigned long long profile_nonlinear_calls = 0ULL;
    unsigned long long profile_samples = 0ULL;
    check_cuda_header80(cudaMemcpyFromSymbol(&profile_total_cycles, g_hoohash_profile_total_cycles, sizeof(profile_total_cycles)), "read HooHash total cycles");
    check_cuda_header80(cudaMemcpyFromSymbol(&profile_nonlinear_cycles, g_hoohash_profile_nonlinear_cycles, sizeof(profile_nonlinear_cycles)), "read HooHash nonlinear cycles");
    check_cuda_header80(cudaMemcpyFromSymbol(&profile_nonlinear_calls, g_hoohash_profile_nonlinear_calls, sizeof(profile_nonlinear_calls)), "read HooHash nonlinear calls");
    check_cuda_header80(cudaMemcpyFromSymbol(&profile_samples, g_hoohash_profile_samples, sizeof(profile_samples)), "read HooHash samples");
    const double profile_nonlinear_fraction = profile_total_cycles != 0ULL
        ? static_cast<double>(profile_nonlinear_cycles) / static_cast<double>(profile_total_cycles)
        : 0.0;
    const double profile_cycles_per_call = profile_nonlinear_calls != 0ULL
        ? static_cast<double>(profile_nonlinear_cycles) / static_cast<double>(profile_nonlinear_calls)
        : 0.0;
    std::fprintf(stderr,
                 "PEPEW_HOOHASH_CYCLE_PROFILE count=%zu samples=%llu total_cycles=%llu nonlinear_cycles=%llu nonlinear_calls=%llu nonlinear_fraction=%.6f cycles_per_nonlinear=%.3f\\n",
                 count, profile_samples, profile_total_cycles, profile_nonlinear_cycles,
                 profile_nonlinear_calls, profile_nonlinear_fraction, profile_cycles_per_call);
#endif'''
fused_idx = p.find(fused_check, launch_idx)
if fused_idx < 0:
    raise SystemExit('fusion2 fused launch check not found')
fused_end = fused_idx + len(fused_check)
p = p[:fused_end] + readback + p[fused_end:]
part.write_text(p)
print('instrumented sampled HooHash nonlinear cycle profile')
