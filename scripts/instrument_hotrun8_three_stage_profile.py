#!/usr/bin/env python3
from pathlib import Path

p = Path('native/src/cuda/v1/header80_backend_part07.inc')
s = p.read_text()
old = '''#else
    header80_first_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin), work_words, count);
    check_cuda_header80(cudaGetLastError(), "header80_first_kernel launch");
#if defined(PEPEPOW_CUDA_HOTRUN8) && PEPEPOW_CUDA_HOTRUN8
    hoohash_mix_hotrun8_split_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_), work_words, count);
    check_cuda_header80(cudaGetLastError(), "hoohash_mix_hotrun8_split_kernel launch");
#else
    hoohash_mix_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_), work_words, count);
    check_cuda_header80(cudaGetLastError(), "hoohash_mix_kernel launch");
#endif
    header80_final_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin), work_words,
        static_cast<DeviceShareResult*>(device_result_), count);
    check_cuda_header80(cudaGetLastError(), "header80_final_kernel launch");
#endif
'''
new = '''#else
#if defined(PEPEPOW_CUDA_STAGE_PROFILE) && PEPEPOW_CUDA_STAGE_PROFILE == 2
    static thread_local cudaEvent_t profile3_begin{};
    static thread_local cudaEvent_t profile3_after_first{};
    static thread_local cudaEvent_t profile3_after_hoohash{};
    static thread_local cudaEvent_t profile3_end{};
    static thread_local bool profile3_ready = false;
    if (!profile3_ready) {
        check_cuda_header80(cudaEventCreate(&profile3_begin), "cudaEventCreate(profile3 begin)");
        check_cuda_header80(cudaEventCreate(&profile3_after_first), "cudaEventCreate(profile3 after first)");
        check_cuda_header80(cudaEventCreate(&profile3_after_hoohash), "cudaEventCreate(profile3 after hoohash)");
        check_cuda_header80(cudaEventCreate(&profile3_end), "cudaEventCreate(profile3 end)");
        profile3_ready = true;
    }
    check_cuda_header80(cudaEventRecord(profile3_begin), "cudaEventRecord(profile3 begin)");
#endif
    header80_first_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin), work_words, count);
    check_cuda_header80(cudaGetLastError(), "header80_first_kernel launch");
#if defined(PEPEPOW_CUDA_STAGE_PROFILE) && PEPEPOW_CUDA_STAGE_PROFILE == 2
    check_cuda_header80(cudaEventRecord(profile3_after_first), "cudaEventRecord(profile3 after first)");
#endif
#if defined(PEPEPOW_CUDA_HOTRUN8) && PEPEPOW_CUDA_HOTRUN8
    hoohash_mix_hotrun8_split_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_), work_words, count);
    check_cuda_header80(cudaGetLastError(), "hoohash_mix_hotrun8_split_kernel launch");
#else
    hoohash_mix_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_), work_words, count);
    check_cuda_header80(cudaGetLastError(), "hoohash_mix_kernel launch");
#endif
#if defined(PEPEPOW_CUDA_STAGE_PROFILE) && PEPEPOW_CUDA_STAGE_PROFILE == 2
    check_cuda_header80(cudaEventRecord(profile3_after_hoohash), "cudaEventRecord(profile3 after hoohash)");
#endif
    header80_final_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin), work_words,
        static_cast<DeviceShareResult*>(device_result_), count);
    check_cuda_header80(cudaGetLastError(), "header80_final_kernel launch");
#if defined(PEPEPOW_CUDA_STAGE_PROFILE) && PEPEPOW_CUDA_STAGE_PROFILE == 2
    check_cuda_header80(cudaEventRecord(profile3_end), "cudaEventRecord(profile3 end)");
    check_cuda_header80(cudaEventSynchronize(profile3_end), "cudaEventSynchronize(profile3 end)");
    float profile3_first_ms = 0.0F;
    float profile3_hoohash_ms = 0.0F;
    float profile3_final_ms = 0.0F;
    check_cuda_header80(cudaEventElapsedTime(&profile3_first_ms, profile3_begin, profile3_after_first), "cudaEventElapsedTime(profile3 first)");
    check_cuda_header80(cudaEventElapsedTime(&profile3_hoohash_ms, profile3_after_first, profile3_after_hoohash), "cudaEventElapsedTime(profile3 hoohash)");
    check_cuda_header80(cudaEventElapsedTime(&profile3_final_ms, profile3_after_hoohash, profile3_end), "cudaEventElapsedTime(profile3 final)");
    const double profile3_total_ms = static_cast<double>(profile3_first_ms) + static_cast<double>(profile3_hoohash_ms) + static_cast<double>(profile3_final_ms);
    std::fprintf(stderr,
                 "PEPEW_STAGE_PROFILE3 count=%zu first_blake3_ms=%.6f hoohash_ms=%.6f final_blake3_ms=%.6f first_fraction=%.6f hoohash_fraction=%.6f final_fraction=%.6f\\n",
                 count, static_cast<double>(profile3_first_ms), static_cast<double>(profile3_hoohash_ms), static_cast<double>(profile3_final_ms),
                 profile3_total_ms > 0.0 ? static_cast<double>(profile3_first_ms) / profile3_total_ms : 0.0,
                 profile3_total_ms > 0.0 ? static_cast<double>(profile3_hoohash_ms) / profile3_total_ms : 0.0,
                 profile3_total_ms > 0.0 ? static_cast<double>(profile3_final_ms) / profile3_total_ms : 0.0);
#endif
#endif
'''
if old not in s:
    raise SystemExit('three-stage production block not found')
p.write_text(s.replace(old, new, 1))
print('instrumented three-stage production path')
