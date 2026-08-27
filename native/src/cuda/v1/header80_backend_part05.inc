    double warm_contribution = 0.0;
    if (active) {
#if PEPEPOW_CUDA_SCALED_NIBBLE_TABLE
        warm_contribution = __ldg(
            scaled_nibble_table +
            static_cast<std::size_t>(cell_index) * 16U + nibble);
#elif PEPEPOW_CUDA_SCALED_MATRIX
        warm_contribution = kHeader80ScaledMatrix[cell_index] * value;
#else
        warm_contribution = matrix[cell_index] * 0.0001 * value;
#endif
    }

    double task_x = 0.0;
    if (task) {
        const double cell = matrix[cell_index];
        task_x = cell * hash_mod * value + nonce_mod;
    }

    // Deterministic owner slot: no ballot/atomicAdd compaction and no
    // task_owner lookup.  Inactive/warm owners explicitly publish task=0 so
    // service workers can safely scan all 704 slots after the barrier.
    const unsigned int owner = static_cast<unsigned int>(threadIdx.x);
    scratch.task[owner] = task ? 1U : 0U;
    if (task) {
        scratch.task_x[owner] = task_x;
        scratch.task_value[owner] = value;
    }

    __syncthreads();
    constexpr unsigned int kServiceThreads = 128U;
    if (owner < kServiceThreads) {
        for (unsigned int slot = owner;
             slot < static_cast<unsigned int>(PEPEPOW_CUDA_THREADS);
             slot += kServiceThreads) {
            if (scratch.task[slot] != 0U) {
                const double nonlinear_value =
                    safe_nonlinear(scratch.task_x[slot]);
                scratch.task_result[slot] =
                    nonlinear_value * scratch.task_value[slot] * 1234.0;
            }
        }
    }
    __syncthreads();

    if (active) {
        if (cold) {
            if (nibble != 0U) {
                sum += scratch.task_result[owner];
            }
        } else {
            sum += warm_contribution;
        }
        update_sw_state(sw, sum);
    }
}

__device__ __forceinline__ double matrix_row_service(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    int row, const std::uint32_t first_pass[8], double hash_mod_fp64,
    double nonce_mod, HooHashSwState& sw, bool active,
    ColdServiceScratch& scratch) {
    double sum = 0.0;
    const int row_offset = row * 64;
    #pragma unroll 1
    for (int word_index = 0; word_index < 8; ++word_index) {
        const std::uint32_t packed_word = first_pass[word_index];
        #pragma unroll
        for (int byte_in_word = 0; byte_in_word < 4; ++byte_in_word) {
            const int byte_index = word_index * 4 + byte_in_word;
            const std::uint8_t packed = static_cast<std::uint8_t>(
                packed_word >>
                static_cast<unsigned int>(byte_in_word * 8));
            const int high_cell = row_offset + byte_index * 2;
            const std::uint32_t high_nibble =
                static_cast<std::uint32_t>(packed >> 4U);
            const std::uint32_t low_nibble =
                static_cast<std::uint32_t>(packed & 0x0fU);
            service_accumulate(
                matrix, scaled_nibble_table, high_cell, high_nibble,
                nibble_to_double(high_nibble), hash_mod_fp64, nonce_mod,
                sum, sw, active, scratch);
            service_accumulate(
                matrix, scaled_nibble_table, high_cell + 1, low_nibble,
                nibble_to_double(low_nibble), hash_mod_fp64, nonce_mod,
                sum, sw, active, scratch);
        }
    }
    return sum;
}

__device__ __forceinline__ void hoohash_mix_words_service(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    std::uint32_t mix_nonce, const std::uint32_t first_pass[8],
    std::uint32_t mixed[8], bool active, ColdServiceScratch& scratch) {
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
        const double even_sum = matrix_row_service(
            matrix, scaled_nibble_table, pair * 2, first_pass,
            hash_mod_fp64, nonce_mod, sw, active, scratch);
        const double odd_sum = matrix_row_service(
            matrix, scaled_nibble_table, pair * 2 + 1, first_pass,
            hash_mod_fp64, nonce_mod, sw, active, scratch);
        if (active) {
            const std::uint64_t combined =
                positive_double_to_u64_rz(even_sum) +
                positive_double_to_u64_rz(odd_sum);
            const std::uint32_t shift =
                static_cast<std::uint32_t>((pair & 3) * 8);
            mixed[pair >> 2] ^=
                static_cast<std::uint32_t>(combined & 0xffU) << shift;
        }
    }
}

__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void header80_pow_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    DeviceShareResult* __restrict__ result,
    std::size_t count) {
    __shared__ ColdServiceScratch scratch;

    const std::size_t index =
        static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
