            cudaMemcpyToSymbol(kHeader80Midstate, midstate.data(), sizeof(midstate),
                               0, cudaMemcpyHostToDevice),
            "cudaMemcpyToSymbol(header80 midstate)");
        check_cuda_header80(
            cudaMemcpyToSymbol(kHeader80TailWords, tail_words.data(), sizeof(tail_words),
                               0, cudaMemcpyHostToDevice),
            "cudaMemcpyToSymbol(header80 tail)");
        cached_matrix_seed = matrix_seed;
        cached_device = device_index_;
        header_cached = true;
    }

    static thread_local bool target_cached = false;
    static thread_local std::array<std::uint8_t, 32> cached_target{};
    std::array<std::uint8_t, 32> target_copy{};
    std::copy(target.begin(), target.end(), target_copy.begin());
    if (!target_cached || cached_target != target_copy) {
        std::array<std::uint32_t, 8> target_words{};
        for (int i = 0; i < 8; ++i) {
            target_words[static_cast<std::size_t>(i)] = host_load_be32(target.data() + i * 4);
        }
        check_cuda_header80(
            cudaMemcpyToSymbol(kHeader80TargetWords, target_words.data(), sizeof(target_words),
                               0, cudaMemcpyHostToDevice),
            "cudaMemcpyToSymbol(header80 target words)");
        cached_target = target_copy;
        target_cached = true;
    }

    if (device_result_ == nullptr) {
        check_cuda_header80(cudaMalloc(&device_result_, sizeof(DeviceShareResult)),
                            "cudaMalloc(header80 result)");
    }
    check_cuda_header80(cudaMemset(device_result_, 0, sizeof(std::uint32_t)),
                        "cudaMemset(header80 found flag)");

    constexpr unsigned int threads = static_cast<unsigned int>(PEPEPOW_CUDA_THREADS);
    const unsigned int blocks = static_cast<unsigned int>((count + threads - 1U) / threads);

#if PEPEPOW_CUDA_SPLIT_PIPELINE
    if (device_work_ == nullptr || device_work_capacity_ < count) {
        if (device_work_ != nullptr) {
            check_cuda_header80(cudaFree(device_work_), "cudaFree(header80 work resize)");
        }
        check_cuda_header80(
            cudaMalloc(&device_work_, count *
// Only the global resident variant needs the second mixed-word region.
// The local-phase variant stores those words in thread-local phase_cache.
#if defined(PEPEPOW_CUDA_LOCAL_RESIDENCY) && PEPEPOW_CUDA_LOCAL_RESIDENCY && \
    !(defined(PEPEPOW_CUDA_HOTRUN8) && PEPEPOW_CUDA_HOTRUN8 && \
      defined(PEPEPOW_CUDA_HOTRUN8_FUSION_MODE) && PEPEPOW_CUDA_HOTRUN8_FUSION_MODE == 2 && \
      defined(PEPEPOW_CUDA_RUNTIME_LOCAL_PHASE_CACHE) && PEPEPOW_CUDA_RUNTIME_LOCAL_PHASE_CACHE)
                       16U *
#else
                       8U *
#endif
                       sizeof(std::uint32_t)),
            "cudaMalloc(header80 split work)");
        device_work_capacity_ = count;
    }
    static thread_local bool cache_configured = false;
    if (!cache_configured) {
#if defined(PEPEPOW_CUDA_HOTRUN8) && PEPEPOW_CUDA_HOTRUN8
  #if defined(PEPEPOW_CUDA_HOTRUN8_FUSION_MODE) && PEPEPOW_CUDA_HOTRUN8_FUSION_MODE == 1
        check_cuda_header80(
            cudaFuncSetCacheConfig(header80_first_hoohash_hotrun8_fused_kernel, cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(first+hoohash hotrun8 fusion)");
  #elif defined(PEPEPOW_CUDA_HOTRUN8_FUSION_MODE) && PEPEPOW_CUDA_HOTRUN8_FUSION_MODE == 2
        check_cuda_header80(
#if defined(PEPEPOW_CUDA_LOCAL_RESIDENCY) && PEPEPOW_CUDA_LOCAL_RESIDENCY
  #if defined(PEPEPOW_CUDA_RUNTIME_LOCAL_PHASE_CACHE) && PEPEPOW_CUDA_RUNTIME_LOCAL_PHASE_CACHE
            cudaFuncSetCacheConfig(hoohash_final_hotrun8_local_phase_kernel, cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(hoohash+final hotrun8 local phase)"
  #else
            cudaFuncSetCacheConfig(hoohash_final_hotrun8_resident_kernel, cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(hoohash+final hotrun8 resident)"
  #endif
#else
            cudaFuncSetCacheConfig(hoohash_final_hotrun8_fused_kernel, cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(hoohash+final hotrun8 fusion)"
#endif
        );
  #else
        check_cuda_header80(
            cudaFuncSetCacheConfig(hoohash_mix_hotrun8_split_kernel, cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(hoohash hotrun8 split)");
  #endif
#else
        check_cuda_header80(
            cudaFuncSetCacheConfig(hoohash_mix_kernel, cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(hoohash mix)");
#endif
        cache_configured = true;
    }
    auto* work_words = static_cast<std::uint32_t*>(device_work_);
#if defined(PEPEPOW_CUDA_HOTRUN8) && PEPEPOW_CUDA_HOTRUN8 && defined(PEPEPOW_CUDA_HOTRUN8_FUSION_MODE) && PEPEPOW_CUDA_HOTRUN8_FUSION_MODE == 1
    header80_first_hoohash_hotrun8_fused_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_), work_words, count);
    check_cuda_header80(cudaGetLastError(), "header80_first_hoohash_hotrun8_fused_kernel launch");
    header80_final_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin), work_words,
        static_cast<DeviceShareResult*>(device_result_), count);
    check_cuda_header80(cudaGetLastError(), "header80_final_kernel launch");
#elif defined(PEPEPOW_CUDA_HOTRUN8) && PEPEPOW_CUDA_HOTRUN8 && defined(PEPEPOW_CUDA_HOTRUN8_FUSION_MODE) && PEPEPOW_CUDA_HOTRUN8_FUSION_MODE == 2
#if defined(PEPEPOW_CUDA_STAGE_TIMING) && PEPEPOW_CUDA_STAGE_TIMING
    static thread_local cudaEvent_t stage_start = nullptr;
    static thread_local cudaEvent_t stage_boundary = nullptr;
    static thread_local cudaEvent_t stage_stop = nullptr;
    if (stage_start == nullptr) {
        check_cuda_header80(cudaEventCreate(&stage_start), "cudaEventCreate(stage start)");
        check_cuda_header80(cudaEventCreate(&stage_boundary), "cudaEventCreate(stage boundary)");
        check_cuda_header80(cudaEventCreate(&stage_stop), "cudaEventCreate(stage stop)");
    }
    check_cuda_header80(cudaEventRecord(stage_start), "cudaEventRecord(stage start)");
#endif
    header80_first_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin), work_words, count);
    check_cuda_header80(cudaGetLastError(), "header80_first_kernel launch");
#if defined(PEPEPOW_CUDA_STAGE_TIMING) && PEPEPOW_CUDA_STAGE_TIMING
    check_cuda_header80(cudaEventRecord(stage_boundary), "cudaEventRecord(stage boundary)");
#endif
#if defined(PEPEPOW_CUDA_LOCAL_RESIDENCY) && PEPEPOW_CUDA_LOCAL_RESIDENCY
  #if defined(PEPEPOW_CUDA_RUNTIME_LOCAL_PHASE_CACHE) && PEPEPOW_CUDA_RUNTIME_LOCAL_PHASE_CACHE
    hoohash_final_hotrun8_local_phase_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_), work_words,
        static_cast<DeviceShareResult*>(device_result_), count);
    check_cuda_header80(cudaGetLastError(), "hoohash_final_hotrun8_local_phase_kernel launch");
  #else
    hoohash_final_hotrun8_resident_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_), work_words,
        work_words + count * 8U,
        static_cast<DeviceShareResult*>(device_result_), count);
    check_cuda_header80(cudaGetLastError(), "hoohash_final_hotrun8_resident_kernel launch");
  #endif
#else
    hoohash_final_hotrun8_fused_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_), work_words,
        static_cast<DeviceShareResult*>(device_result_), count);
    check_cuda_header80(cudaGetLastError(), "hoohash_final_hotrun8_fused_kernel launch");
#endif
#if defined(PEPEPOW_CUDA_STAGE_TIMING) && PEPEPOW_CUDA_STAGE_TIMING
    check_cuda_header80(cudaEventRecord(stage_stop), "cudaEventRecord(stage stop)");
#endif
#else
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
#else
    static thread_local bool cache_configured = false;
    if (!cache_configured) {
#if defined(PEPEPOW_CUDA_HOTRUN8) && PEPEPOW_CUDA_HOTRUN8
        check_cuda_header80(
            cudaFuncSetCacheConfig(header80_pow_hotrun8_kernel, cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(header80 hotrun8)");
#else
        check_cuda_header80(
            cudaFuncSetCacheConfig(header80_pow_kernel, cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(header80 monolithic)");
#endif
        cache_configured = true;
    }
#if defined(PEPEPOW_CUDA_HOTRUN8) && PEPEPOW_CUDA_HOTRUN8
    header80_pow_hotrun8_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_),
        static_cast<DeviceShareResult*>(device_result_), count);
    check_cuda_header80(cudaGetLastError(), "header80_pow_hotrun8_kernel launch");
#else
    header80_pow_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_),
        static_cast<DeviceShareResult*>(device_result_), count);
    check_cuda_header80(cudaGetLastError(), "header80_pow_kernel launch");
#endif
#endif

    DeviceShareResult host_result{};
    check_cuda_header80(
        cudaMemcpy(&host_result, device_result_, sizeof(host_result), cudaMemcpyDeviceToHost),
        "cudaMemcpy(header80 result)");
#if defined(PEPEPOW_CUDA_STAGE_TIMING) && PEPEPOW_CUDA_STAGE_TIMING && \
    defined(PEPEPOW_CUDA_SPLIT_PIPELINE) && PEPEPOW_CUDA_SPLIT_PIPELINE && \
    defined(PEPEPOW_CUDA_HOTRUN8) && PEPEPOW_CUDA_HOTRUN8 && \
    defined(PEPEPOW_CUDA_HOTRUN8_FUSION_MODE) && PEPEPOW_CUDA_HOTRUN8_FUSION_MODE == 2
    float first_ms = 0.0F;
    float final_ms = 0.0F;
    check_cuda_header80(
        cudaEventElapsedTime(&first_ms, stage_start, stage_boundary),
        "cudaEventElapsedTime(header80 first)");
    check_cuda_header80(
        cudaEventElapsedTime(&final_ms, stage_boundary, stage_stop),
        "cudaEventElapsedTime(hoohash final)");
    std::fprintf(stderr,
                 "CUDA_STAGE_TIMING nonces=%zu first_ms=%.6f hoohash_final_ms=%.6f total_ms=%.6f\n",
                 count, static_cast<double>(first_ms), static_cast<double>(final_ms),
                 static_cast<double>(first_ms + final_ms));
#endif
#if defined(PEPEPOW_CUDA_SUBSTAGE_TIMING) && PEPEPOW_CUDA_SUBSTAGE_TIMING
#if !(defined(PEPEPOW_CUDA_SPLIT_PIPELINE) && PEPEPOW_CUDA_SPLIT_PIPELINE && \
      defined(PEPEPOW_CUDA_HOTRUN8) && PEPEPOW_CUDA_HOTRUN8 && \
      defined(PEPEPOW_CUDA_HOTRUN8_FUSION_MODE) && PEPEPOW_CUDA_HOTRUN8_FUSION_MODE == 2 && \
      defined(PEPEPOW_CUDA_LOCAL_RESIDENCY) && PEPEPOW_CUDA_LOCAL_RESIDENCY && \
      defined(PEPEPOW_CUDA_RUNTIME_LOCAL_PHASE_CACHE) && PEPEPOW_CUDA_RUNTIME_LOCAL_PHASE_CACHE)
#error "SUBSTAGE_TIMING requires split hotrun8 fusion2 local-phase configuration"
#endif
    std::array<unsigned long long, 1024 * 2> substage_cycles{};
    const std::size_t substage_samples = std::min<std::size_t>(blocks, 1024);
    check_cuda_header80(cudaMemcpyFromSymbol(substage_cycles.data(), kHeader80SubstageCycles,
                          substage_samples * 2 * sizeof(unsigned long long)),
                        "cudaMemcpyFromSymbol(substage cycles)");
    double mix_sum = 0.0, final_sum = 0.0;
    unsigned long long mix_min = ~0ULL, mix_max = 0, final_min = ~0ULL, final_max = 0;
    for (std::size_t i = 0; i < substage_samples; ++i) {
        const auto mix = substage_cycles[i * 2], final = substage_cycles[i * 2 + 1];
        if (mix == 0 || final == 0) throw std::runtime_error("invalid substage sample");
        mix_sum += static_cast<double>(mix);
        final_sum += static_cast<double>(final);
        mix_min = std::min(mix_min, mix); mix_max = std::max(mix_max, mix);
        final_min = std::min(final_min, final); final_max = std::max(final_max, final);
    }
    std::fprintf(stderr, "CUDA_SUBSTAGE_TIMING nonces=%zu samples=%zu mix_cycles_mean=%.3f final_blake_cycles_mean=%.3f mix_cycles_min=%llu mix_cycles_max=%llu final_cycles_min=%llu final_cycles_max=%llu diagnostic_only=1\n",
                 count, substage_samples, mix_sum / substage_samples, final_sum / substage_samples,
                 mix_min, mix_max, final_min, final_max);
#endif
    if (host_result.found == 0U) return std::nullopt;

    Hash256 hash{};
    for (int word_index = 0; word_index < 8; ++word_index) {
        const std::uint32_t word = host_result.hash_words[word_index];
        hash[static_cast<std::size_t>(word_index * 4)] = static_cast<std::uint8_t>(word);
        hash[static_cast<std::size_t>(word_index * 4 + 1)] = static_cast<std::uint8_t>(word >> 8U);
        hash[static_cast<std::size_t>(word_index * 4 + 2)] = static_cast<std::uint8_t>(word >> 16U);
        hash[static_cast<std::size_t>(word_index * 4 + 3)] = static_cast<std::uint8_t>(word >> 24U);
    }
    return ShareCandidate{job.job_id, host_result.nonce, hash};
}

} // namespace pepepow