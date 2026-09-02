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
}


#if defined(PEPEPOW_CUDA_LOCAL_RESIDENCY) && PEPEPOW_CUDA_LOCAL_RESIDENCY
// Exact single-kernel residency inversion. first_pass remains in the existing
// global work buffer while only one mixed word is live at a time. A disjoint
// second work-buffer region carries the completed mixed words into final
// BLAKE3. This changes storage residency only: row, FP64 accumulation, SW
// transition and pair-combine order are identical to the promoted path.
__device__ __noinline__ void hoohash_mix_words_hotrun8_resident(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    std::uint32_t mix_nonce,
    const std::uint32_t* __restrict__ first_pass,
    std::uint32_t* __restrict__ mixed_out) {
    std::uint32_t hash_xor = 0U;
    #pragma unroll
    for (int i = 0; i < 8; ++i) hash_xor ^= first_pass[i];

    const std::uint32_t hash_mod = byte_swap32(hash_xor);
    const double hash_mod_fp64 = u32_to_double_exact(hash_mod);
    const double nonce_mod = u32_to_double_exact(mix_nonce & 0xffU);
    HooHashSwState sw = initial_sw_state();
    std::uint32_t mixed_word = first_pass[0];

    #pragma unroll 1
    for (int pair = 0; pair < 32; ++pair) {
        const double even_sum = matrix_row_hotrun8_active(
            matrix, scaled_nibble_table, pair * 2, first_pass,
            hash_mod_fp64, nonce_mod, sw);
        const double odd_sum = matrix_row_hotrun8_active(
            matrix, scaled_nibble_table, pair * 2 + 1, first_pass,
            hash_mod_fp64, nonce_mod, sw);
        const std::uint64_t combined =
            positive_double_to_u64_rz(even_sum) +
            positive_double_to_u64_rz(odd_sum);
        const std::uint32_t lane = static_cast<std::uint32_t>(pair & 3);
        mixed_word ^= static_cast<std::uint32_t>(combined & 0xffU) << (lane * 8U);
        if (lane == 3U) {
            const int word = pair >> 2;
            mixed_out[word] = mixed_word;
            if (word != 7) mixed_word = first_pass[word + 1];
        }
    }
}

__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void hoohash_final_hotrun8_resident_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    const std::uint32_t* __restrict__ first_words,
    std::uint32_t* __restrict__ mixed_words,
    DeviceShareResult* __restrict__ result,
    std::size_t count) {
    const std::size_t index =
        static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) return;

    const std::size_t base = index * 8U;
    const std::uint32_t nonce =
        first_nonce + static_cast<std::uint32_t>(index);
    const std::uint32_t* first_pass = first_words + base;
    std::uint32_t* mixed = mixed_words + base;
    hoohash_mix_words_hotrun8_resident(
        matrix, scaled_nibble_table, byte_swap32(nonce), first_pass, mixed);

    std::uint32_t final_hash[8];
    blake3_32_words(mixed, final_hash);
    if (!hash_words_meet_target(final_hash)) return;
    if (atomicCAS(&result->found, 0U, 1U) == 0U) {
        result->nonce = nonce;
        #pragma unroll
        for (int i = 0; i < 8; ++i) result->hash_words[i] = final_hash[i];
    }
}
#endif
