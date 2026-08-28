// Profiling-driven exact HooHash candidate. The production fusion2 topology is
// retained, but warm cells are processed in pairs when a monotonic certificate
// proves that both sums remain inside the same 1024-wide state bin. In that
// case the intermediate SW-state update is redundant: the entry state is warm,
// all contributions are non-negative, and no 1024 wrap can occur. If the proof
// fails, the original exact per-cell state transition path is executed. Cold
// cells always use safe_nonlinear(). No approximate result can reach submission.

__device__ __forceinline__ std::uint32_t hotrun8_nibble(
    const std::uint32_t first_pass[8], int col) {
    const std::uint8_t packed = word_byte(first_pass, col >> 1);
    return (col & 1) == 0
        ? static_cast<std::uint32_t>(packed >> 4U)
        : static_cast<std::uint32_t>(packed & 0x0fU);
}

__device__ __forceinline__ double hotrun8_warm_contribution(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    int cell_index, std::uint32_t nibble) {
#if PEPEPOW_CUDA_SCALED_NIBBLE_TABLE
    return __ldg(scaled_nibble_table +
                 static_cast<std::size_t>(cell_index) * 16U + nibble);
#elif PEPEPOW_CUDA_SCALED_MATRIX
    return kHeader80ScaledMatrix[cell_index] * nibble_to_double(nibble);
#else
    return matrix[cell_index] * 0.0001 * nibble_to_double(nibble);
#endif
}

__device__ __forceinline__ bool hotrun2_same_1024_bin(double a, double b) {
    // For non-negative finite consensus sums, floor(sum) >> 10 is exactly the
    // 1024-wide bin used by frac(sum / 1024). Equality proves that a monotonic
    // pair cannot wrap the fractional state between its entry and final sum.
    return (positive_double_to_u64_rz(a) >> 10U) ==
           (positive_double_to_u64_rz(b) >> 10U);
}

__device__ __forceinline__ double matrix_row_hotrun8(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    int row, const std::uint32_t first_pass[8], double hash_mod_fp64,
    double nonce_mod, HooHashSwState& sw) {
    double sum = 0.0;
    const int row_offset = row * 64;

    #pragma unroll 1
    for (int col = 0; col < 64;) {
        if (!sw_state_is_cold(sw) && col <= 62) {
            const int cell0 = row_offset + col;
            const int cell1 = cell0 + 1;
            const std::uint32_t nibble0 = hotrun8_nibble(first_pass, col);
            const std::uint32_t nibble1 = hotrun8_nibble(first_pass, col + 1);
            const double c0 = hotrun8_warm_contribution(
                matrix, scaled_nibble_table, cell0, nibble0);
            const double c1 = hotrun8_warm_contribution(
                matrix, scaled_nibble_table, cell1, nibble1);
            const double sum1 = sum + c0;
            const double sum2 = sum1 + c1;

            if (hotrun2_same_1024_bin(sum, sum2)) {
                // Entry state is already known warm. Since c0/c1 are
                // non-negative and there is no bin wrap, the intermediate
                // state is also warm. Preserve FP64 addition order and update
                // only the final state of the pair.
                sum = sum2;
                update_sw_state(sw, sum);
                col += 2;
                continue;
            }

            // Exact fallback: commit the first warm cell and evaluate its
            // state transition. The second cell must then respect the new
            // state, including the nonlinear path if the first cell went cold.
            sum = sum1;
            update_sw_state(sw, sum);
            ++col;
            if (sw_state_is_cold(sw)) {
                continue;
            }

            sum += c1;
            update_sw_state(sw, sum);
            ++col;
            continue;
        }

        const int cell = row_offset + col;
        const std::uint32_t nibble = hotrun8_nibble(first_pass, col);
        if (sw_state_is_cold(sw)) {
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
        ++col;
    }
    return sum;
}

// Keep the long HooHash state machine behind a call boundary. Inlining it into
// the BLAKE3 wrapper extends first_pass/mixed/final_hash lifetimes across all 64
// rows and made ptxas spill 132 B in each direction on sm_70.
__device__ __noinline__ void hoohash_mix_words_hotrun8(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    std::uint32_t mix_nonce, const std::uint32_t first_pass[8],
    std::uint32_t mixed[8]) {
    std::uint32_t hash_xor = 0U;
    #pragma unroll
    for (int i = 0; i < 8; ++i) {
        hash_xor ^= first_pass[i];
        mixed[i] = first_pass[i];
    }
    const std::uint32_t hash_mod = byte_swap32(hash_xor);
    const double hash_mod_fp64 = u32_to_double_exact(hash_mod);
    const double nonce_mod = u32_to_double_exact(mix_nonce & 0xffU);
    HooHashSwState sw = initial_sw_state();

    #pragma unroll 1
    for (int pair = 0; pair < 32; ++pair) {
        const double even_sum = matrix_row_hotrun8(
            matrix, scaled_nibble_table, pair * 2, first_pass,
            hash_mod_fp64, nonce_mod, sw);
        const double odd_sum = matrix_row_hotrun8(
            matrix, scaled_nibble_table, pair * 2 + 1, first_pass,
            hash_mod_fp64, nonce_mod, sw);
        const std::uint64_t combined =
            positive_double_to_u64_rz(even_sum) +
            positive_double_to_u64_rz(odd_sum);
        const std::uint32_t shift = static_cast<std::uint32_t>((pair & 3) * 8);
        mixed[pair >> 2] ^=
            static_cast<std::uint32_t>(combined & 0xffU) << shift;
    }
}

// Split middle-stage probe/candidate. The first BLAKE3 result lives in the
// existing global work buffer, so the HooHash kernel owns only first_pass +
// mixed state. This deliberately trades 64 B/nonce of global round-trip for a
// hard register-lifetime boundary. Consensus order and exact nonlinear math are
// identical to the monolithic hot-run path.
__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void hoohash_mix_hotrun8_split_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    std::uint32_t* __restrict__ work_words,
    std::size_t count) {
    const std::size_t index =
        static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) return;

    std::uint32_t first_pass[8];
    std::uint32_t mixed[8];
    const std::size_t base = index * 8U;
    #pragma unroll
    for (int i = 0; i < 8; ++i) first_pass[i] = work_words[base + i];

    const std::uint32_t nonce =
        first_nonce + static_cast<std::uint32_t>(index);
    hoohash_mix_words_hotrun8(
        matrix, scaled_nibble_table, byte_swap32(nonce), first_pass, mixed);

    #pragma unroll
    for (int i = 0; i < 8; ++i) work_words[base + i] = mixed[i];
}

#if !PEPEPOW_CUDA_SPLIT_PIPELINE
__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void header80_pow_hotrun8_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    DeviceShareResult* __restrict__ result,
    std::size_t count) {
    const std::size_t index =
        static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) return;

    const std::uint32_t nonce =
        first_nonce + static_cast<std::uint32_t>(index);
    std::uint32_t first_pass[8];
    std::uint32_t mixed[8];
    std::uint32_t final_hash[8];
    blake3_header80_words(nonce, first_pass);
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
#endif
