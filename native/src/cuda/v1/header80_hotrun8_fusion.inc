// Exact two-stage fusion kernels for the proven hotrun8 split path.
// This file is included inside pepepow's anonymous CUDA namespace after
// header80_hotrun8.inc, so all exact BLAKE3/HooHash helpers are available.

// Stage A+B fused: Header80 BLAKE3 -> exact hotrun8 HooHash -> global mixed[8].
// Removes the first_pass global round-trip while keeping final BLAKE3 separate.
__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void header80_first_hoohash_hotrun8_fused_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    std::uint32_t* __restrict__ work_words,
    std::size_t count) {
    const std::size_t index =
        static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) return;

    const std::uint32_t nonce =
        first_nonce + static_cast<std::uint32_t>(index);
    std::uint32_t first_pass[8];
    std::uint32_t mixed[8];
    blake3_header80_words(nonce, first_pass);
    hoohash_mix_words_hotrun8(
        matrix, scaled_nibble_table, byte_swap32(nonce), first_pass, mixed);

    std::uint32_t* output = work_words + index * 8U;
    #pragma unroll
    for (int i = 0; i < 8; ++i) output[i] = mixed[i];
}

// Stage B+C fused: global first_pass[8] -> exact hotrun8 HooHash -> final
// BLAKE3/target check. Removes the mixed global round-trip while retaining the
// first BLAKE3 as the register-lifetime boundary.
__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void hoohash_final_hotrun8_fused_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    const std::uint32_t* __restrict__ work_words,
    DeviceShareResult* __restrict__ result,
    std::size_t count) {
#if defined(PEPEPOW_CUDA_DUAL_NONCE_ILP) && PEPEPOW_CUDA_DUAL_NONCE_ILP
    const std::size_t lane_index =
        static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    const std::size_t index0 = lane_index * 2U;
    if (index0 >= count) return;
    const std::size_t index1 = index0 + 1U;
    const bool have1 = index1 < count;

    std::uint32_t first0[8];
    std::uint32_t first1[8];
    std::uint32_t mixed0[8];
    std::uint32_t mixed1[8];
    std::uint32_t final_hash0[8];
    std::uint32_t final_hash1[8];
    const std::size_t base0 = index0 * 8U;
    const std::size_t base1 = index1 * 8U;
    #pragma unroll
    for (int i = 0; i < 8; ++i) {
        first0[i] = work_words[base0 + i];
        first1[i] = have1 ? work_words[base1 + i] : first0[i];
    }

    const std::uint32_t nonce0 =
        first_nonce + static_cast<std::uint32_t>(index0);
    const std::uint32_t nonce1 =
        first_nonce + static_cast<std::uint32_t>(index1);
    if (have1) {
        hoohash_mix_words_hotrun8_dual(
            matrix, scaled_nibble_table,
            byte_swap32(nonce0), first0, mixed0,
            byte_swap32(nonce1), first1, mixed1);
    } else {
        hoohash_mix_words_hotrun8(
            matrix, scaled_nibble_table,
            byte_swap32(nonce0), first0, mixed0);
    }

    blake3_32_words(mixed0, final_hash0);
    if (hash_words_meet_target(final_hash0) &&
        atomicCAS(&result->found, 0U, 1U) == 0U) {
        result->nonce = nonce0;
        #pragma unroll
        for (int i = 0; i < 8; ++i) result->hash_words[i] = final_hash0[i];
    }

    if (have1) {
        blake3_32_words(mixed1, final_hash1);
        if (hash_words_meet_target(final_hash1) &&
            atomicCAS(&result->found, 0U, 1U) == 0U) {
            result->nonce = nonce1;
            #pragma unroll
            for (int i = 0; i < 8; ++i) result->hash_words[i] = final_hash1[i];
        }
    }
#else
    const std::size_t index =
        static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) return;

    const std::size_t base = index * 8U;
    std::uint32_t first_pass[8];
    std::uint32_t mixed[8];
    std::uint32_t final_hash[8];
    #pragma unroll
    for (int i = 0; i < 8; ++i) first_pass[i] = work_words[base + i];

    const std::uint32_t nonce =
        first_nonce + static_cast<std::uint32_t>(index);
    hoohash_mix_words_hotrun8(
        matrix, scaled_nibble_table, byte_swap32(nonce), first_pass, mixed);
    blake3_32_words(mixed, final_hash);
    if (!hash_words_meet_target(final_hash)) return;
    if (atomicCAS(&result->found, 0U, 1U) == 0U) {
        result->nonce = nonce;
        #pragma unroll
        for (int i = 0; i < 8; ++i) result->hash_words[i] = final_hash[i];
    }
#endif
}
