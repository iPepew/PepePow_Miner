// PepeW Miner v1.0.6 Volta async3 experiment.
// Three resident service warps evaluate the exact nonlinear FP64 regions while
// the remaining warps process independent nonces. Workers communicate through
// per-thread shared-memory mailboxes; there are no block-wide barriers in the
// 4096-cell HooHash hot loop.

struct VoltaAsync3Scratch {
    // state: 0 = idle, 1 = request ready, 2 = result ready.
    unsigned int state[PEPEPOW_CUDA_THREADS];
    unsigned int meta[PEPEPOW_CUDA_THREADS];
    double y[PEPEPOW_CUDA_THREADS];
    double result[PEPEPOW_CUDA_THREADS];
    unsigned int workers_done;
    unsigned int active_workers;
};

__device__ __forceinline__ double volta_async3_region_value(
    unsigned int region, double y) {
    if (region == 0U) {
        double sine, cosine;
        sincos(y, &sine, &cosine);
        return exp(sine + cosine);
    }
    if (region == 1U) {
        if (y == kPi / 2.0 || y == 3.0 * kPi / 2.0) return 0.0;
        const double sine = sin(y);
        return sine * sine;
    }
    return 1.0 / sqrt(fabs(y) + 1.0);
}

__device__ __forceinline__ void volta_async3_service_loop(
    VoltaAsync3Scratch& scratch) {
    const unsigned int service_region =
        static_cast<unsigned int>(threadIdx.x) >> 5U;
    const unsigned int lane =
        static_cast<unsigned int>(threadIdx.x) & 31U;
    constexpr unsigned int kServiceThreads = 96U;

    while (atomicAdd(&scratch.workers_done, 0U) < scratch.active_workers) {
        bool did_work = false;
        for (unsigned int worker = kServiceThreads + lane;
             worker < static_cast<unsigned int>(blockDim.x);
             worker += 32U) {
            if (atomicCAS(&scratch.state[worker], 1U, 1U) != 1U) continue;
            const unsigned int meta = scratch.meta[worker];
            const unsigned int region = meta & 0x3U;
            if (region != service_region) continue;

            const unsigned int nibble = (meta >> 8U) & 0x0fU;
            const double nonlinear_value =
                volta_async3_region_value(region, scratch.y[worker]);
            scratch.result[worker] =
                nonlinear_value * nibble_to_double(nibble) * 1234.0;
            __threadfence_block();
            atomicExch(&scratch.state[worker], 2U);
            did_work = true;
        }

        const unsigned int worked_mask =
            __ballot_sync(0xffffffffU, did_work);
        if (worked_mask == 0U) __nanosleep(32U);
    }
}

__device__ __forceinline__ void volta_async3_accumulate(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    int cell_index, std::uint32_t nibble, double value,
    double hash_mod, double nonce_mod, double& sum, HooHashSwState& sw,
    VoltaAsync3Scratch& scratch) {
    const bool cold = sw_state_is_cold(sw);
    if (cold) {
        if (nibble != 0U) {
            const double cell = matrix[cell_index];
            const double x = cell * hash_mod * value + nonce_mod;
            const HooHashSelectorParts selector =
                decode_selector_parts(x * kTransformMultiplier * 0.125);
            const double two = selector.two;
            double y;
            if (two < 0.25) y = x + (1.0 + two);
            else if (two < 0.50) y = x - (1.0 + two);
            else if (two < 0.75) y = x * (1.0 + two);
            else y = x / (1.0 + two);

            const unsigned int slot = static_cast<unsigned int>(threadIdx.x);
            scratch.y[slot] = y;
            scratch.meta[slot] =
                (selector.one_region & 0x3U) | ((nibble & 0x0fU) << 8U);
            __threadfence_block();
            atomicExch(&scratch.state[slot], 1U);

            while (atomicCAS(&scratch.state[slot], 2U, 2U) != 2U) {
                __nanosleep(32U);
            }
            __threadfence_block();
            sum += scratch.result[slot];
            atomicExch(&scratch.state[slot], 0U);
        }
    } else {
#if PEPEPOW_CUDA_SCALED_NIBBLE_TABLE
        sum += __ldg(
            scaled_nibble_table +
            static_cast<std::size_t>(cell_index) * 16U + nibble);
#elif PEPEPOW_CUDA_SCALED_MATRIX
        sum += kHeader80ScaledMatrix[cell_index] * value;
#else
        sum += matrix[cell_index] * 0.0001 * value;
#endif
    }
    update_sw_state(sw, sum);
}

__device__ __forceinline__ double volta_async3_matrix_row(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    int row, const std::uint32_t first_pass[8], double hash_mod_fp64,
    double nonce_mod, HooHashSwState& sw, VoltaAsync3Scratch& scratch) {
    double sum = 0.0;
    const int row_offset = row * 64;
    #pragma unroll 1
    for (int word_index = 0; word_index < 8; ++word_index) {
        const std::uint32_t packed_word = first_pass[word_index];
        #pragma unroll
        for (int byte_in_word = 0; byte_in_word < 4; ++byte_in_word) {
            const int byte_index = word_index * 4 + byte_in_word;
            const std::uint8_t packed = static_cast<std::uint8_t>(
                packed_word >> static_cast<unsigned int>(byte_in_word * 8));
            const int high_cell = row_offset + byte_index * 2;
            const std::uint32_t high_nibble =
                static_cast<std::uint32_t>(packed >> 4U);
            const std::uint32_t low_nibble =
                static_cast<std::uint32_t>(packed & 0x0fU);
            volta_async3_accumulate(
                matrix, scaled_nibble_table, high_cell, high_nibble,
                nibble_to_double(high_nibble), hash_mod_fp64, nonce_mod,
                sum, sw, scratch);
            volta_async3_accumulate(
                matrix, scaled_nibble_table, high_cell + 1, low_nibble,
                nibble_to_double(low_nibble), hash_mod_fp64, nonce_mod,
                sum, sw, scratch);
        }
    }
    return sum;
}

__device__ __forceinline__ void volta_async3_mix_words(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    std::uint32_t mix_nonce, const std::uint32_t first_pass[8],
    std::uint32_t mixed[8], VoltaAsync3Scratch& scratch) {
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
        const double even_sum = volta_async3_matrix_row(
            matrix, scaled_nibble_table, pair * 2, first_pass,
            hash_mod_fp64, nonce_mod, sw, scratch);
        const double odd_sum = volta_async3_matrix_row(
            matrix, scaled_nibble_table, pair * 2 + 1, first_pass,
            hash_mod_fp64, nonce_mod, sw, scratch);
        const std::uint64_t combined =
            positive_double_to_u64_rz(even_sum) +
            positive_double_to_u64_rz(odd_sum);
        const std::uint32_t shift =
            static_cast<std::uint32_t>((pair & 3) * 8);
        mixed[pair >> 2] ^=
            static_cast<std::uint32_t>(combined & 0xffU) << shift;
    }
}

__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void header80_pow_volta_async3_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    DeviceShareResult* __restrict__ result,
    std::size_t count) {
    constexpr unsigned int kServiceThreads = 96U;
    static_assert(PEPEPOW_CUDA_THREADS > kServiceThreads,
                  "volta-async3 requires worker threads");

    __shared__ VoltaAsync3Scratch scratch;
    scratch.state[threadIdx.x] = 0U;

    const unsigned int worker_threads =
        static_cast<unsigned int>(blockDim.x) - kServiceThreads;
    const std::size_t block_base =
        static_cast<std::size_t>(blockIdx.x) * worker_threads;

    if (threadIdx.x == 0U) {
        const std::size_t remaining =
            block_base < count ? count - block_base : 0U;
        scratch.active_workers = static_cast<unsigned int>(
            remaining < worker_threads ? remaining : worker_threads);
        scratch.workers_done = 0U;
    }
    __syncthreads(); // One launch-time barrier only; none in the HooHash cells.

    if (threadIdx.x < kServiceThreads) {
        volta_async3_service_loop(scratch);
        return;
    }

    const unsigned int worker_lane =
        static_cast<unsigned int>(threadIdx.x) - kServiceThreads;
    const std::size_t index = block_base + worker_lane;
    if (index >= count) return;

    const std::uint32_t nonce =
        first_nonce + static_cast<std::uint32_t>(index);
    std::uint32_t first_pass[8]{};
    std::uint32_t mixed[8]{};
    std::uint32_t final_hash[8]{};

    blake3_header80_words(nonce, first_pass);
    volta_async3_mix_words(
        matrix, scaled_nibble_table, byte_swap32(nonce), first_pass,
        mixed, scratch);
    blake3_32_words(mixed, final_hash);

    if (hash_words_meet_target(final_hash)) {
        if (atomicCAS(&result->found, 0U, 1U) == 0U) {
            result->nonce = nonce;
            #pragma unroll
            for (int i = 0; i < 8; ++i) {
                result->hash_words[i] = final_hash[i];
            }
        }
    }

    __threadfence_block();
    atomicAdd(&scratch.workers_done, 1U);
}
