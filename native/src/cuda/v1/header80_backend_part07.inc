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
            cudaMalloc(&device_work_, count * 8U * sizeof(std::uint32_t)),
            "cudaMalloc(header80 split work)");
        device_work_capacity_ = count;
    }
    static thread_local bool cache_configured = false;
    if (!cache_configured) {
        check_cuda_header80(
            cudaFuncSetCacheConfig(hoohash_mix_kernel, cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(hoohash mix)");
        cache_configured = true;
    }
    auto* work_words = static_cast<std::uint32_t*>(device_work_);
    header80_first_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin), work_words, count);
    check_cuda_header80(cudaGetLastError(), "header80_first_kernel launch");
    hoohash_mix_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_), work_words, count);
    check_cuda_header80(cudaGetLastError(), "hoohash_mix_kernel launch");
    header80_final_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin), work_words,
        static_cast<DeviceShareResult*>(device_result_), count);
    check_cuda_header80(cudaGetLastError(), "header80_final_kernel launch");
#else
    static thread_local bool cache_configured = false;
    if (!cache_configured) {
        check_cuda_header80(
            cudaFuncSetCacheConfig(header80_pow_kernel, cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(header80 monolithic)");
        cache_configured = true;
    }
    header80_pow_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_),
        static_cast<DeviceShareResult*>(device_result_), count);
    check_cuda_header80(cudaGetLastError(), "header80_pow_kernel launch");
#endif

    DeviceShareResult host_result{};
    check_cuda_header80(
        cudaMemcpy(&host_result, device_result_, sizeof(host_result), cudaMemcpyDeviceToHost),
        "cudaMemcpy(header80 result)");
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
