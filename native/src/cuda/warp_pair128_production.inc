// Production-shaped 128-thread named-barrier topology for Volta.
// Two independent 64-thread pairs: warp0 owners <-> warp1 services,
// warp2 owners <-> warp3 services. Each block advances 64 nonces.

struct WarpPair128Scratch {
    double task_x[32];
    double task_value[32];
    double task_result[32];
    unsigned int task[32];
};

__device__ __forceinline__ void warp_pair128_barrier(unsigned int id) {
    asm volatile("bar.sync %0, 64;" :: "r"(id) : "memory");
}

__device__ __forceinline__ void warp_pair128_accumulate(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    int cell_index, std::uint32_t nibble, double value,
    double hash_mod, double nonce_mod, double& sum, HooHashSwState& sw,
    bool owner, bool active, unsigned int lane, unsigned int pair,
    WarpPair128Scratch (&scratch)[2]) {
    const bool cold = owner && active && sw_state_is_cold(sw);
    const bool task = cold && nibble != 0U;

    double warm_contribution = 0.0;
    if (owner && active) {
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

    if (owner) {
        scratch[pair].task[lane] = task ? 1U : 0U;
        if (task) {
            const double cell = matrix[cell_index];
            scratch[pair].task_x[lane] = cell * hash_mod * value + nonce_mod;
            scratch[pair].task_value[lane] = value;
        }
    }

    const unsigned int barrier_id = pair + 1U;
    warp_pair128_barrier(barrier_id);

    if (!owner && scratch[pair].task[lane] != 0U) {
        scratch[pair].task_result[lane] =
            safe_nonlinear(scratch[pair].task_x[lane]) *
            scratch[pair].task_value[lane] * 1234.0;
    }

    warp_pair128_barrier(barrier_id);

    if (owner && active) {
        if (cold) {
            if (nibble != 0U) sum += scratch[pair].task_result[lane];
        } else {
            sum += warm_contribution;
        }
        update_sw_state(sw, sum);
    }
}

__device__ __forceinline__ double warp_pair128_matrix_row(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    int row, const std::uint32_t first_pass[8], double hash_mod_fp64,
    double nonce_mod, HooHashSwState& sw, bool owner, bool active,
    unsigned int lane, unsigned int pair, WarpPair128Scratch (&scratch)[2]) {
    double sum = 0.0;
    const int row_offset = row * 64;
    #pragma unroll 1
    for (int word_index = 0; word_index < 8; ++word_index) {
        const std::uint32_t packed_word = owner ? first_pass[word_index] : 0U;
        #pragma unroll
        for (int byte_in_word = 0; byte_in_word < 4; ++byte_in_word) {
            const int byte_index = word_index * 4 + byte_in_word;
            const std::uint8_t packed = static_cast<std::uint8_t>(
                packed_word >> static_cast<unsigned int>(byte_in_word * 8));
            const int high_cell = row_offset + byte_index * 2;
            const std::uint32_t high_nibble = static_cast<std::uint32_t>(packed >> 4U);
            const std::uint32_t low_nibble = static_cast<std::uint32_t>(packed & 0x0fU);
            warp_pair128_accumulate(
                matrix, scaled_nibble_table, high_cell, high_nibble,
                nibble_to_double(high_nibble), hash_mod_fp64, nonce_mod,
                sum, sw, owner, active, lane, pair, scratch);
            warp_pair128_accumulate(
                matrix, scaled_nibble_table, high_cell + 1, low_nibble,
                nibble_to_double(low_nibble), hash_mod_fp64, nonce_mod,
                sum, sw, owner, active, lane, pair, scratch);
        }
    }
    return sum;
}

__device__ __forceinline__ void warp_pair128_hoohash_mix_words(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    std::uint32_t mix_nonce, const std::uint32_t first_pass[8],
    std::uint32_t mixed[8], bool owner, bool active,
    unsigned int lane, unsigned int pair, WarpPair128Scratch (&scratch)[2]) {
    std::uint32_t hash_xor = 0U;
    #pragma unroll
    for (int i = 0; i < 8; ++i) {
        const std::uint32_t w = owner ? first_pass[i] : 0U;
        hash_xor ^= w;
        mixed[i] = w;
    }
    const std::uint32_t hash_mod = byte_swap32(hash_xor);
    const double hash_mod_fp64 = u32_to_double_exact(hash_mod);
    const double nonce_mod = u32_to_double_exact(mix_nonce & 0xffU);
    HooHashSwState sw = initial_sw_state();
    #pragma unroll 1
    for (int row_pair = 0; row_pair < 32; ++row_pair) {
        const double even_sum = warp_pair128_matrix_row(
            matrix, scaled_nibble_table, row_pair * 2, first_pass,
            hash_mod_fp64, nonce_mod, sw, owner, active, lane, pair, scratch);
        const double odd_sum = warp_pair128_matrix_row(
            matrix, scaled_nibble_table, row_pair * 2 + 1, first_pass,
            hash_mod_fp64, nonce_mod, sw, owner, active, lane, pair, scratch);
        if (owner && active) {
            const std::uint64_t combined =
                positive_double_to_u64_rz(even_sum) + positive_double_to_u64_rz(odd_sum);
            const std::uint32_t shift = static_cast<std::uint32_t>((row_pair & 3) * 8);
            mixed[row_pair >> 2] ^=
                static_cast<std::uint32_t>(combined & 0xffU) << shift;
        }
    }
}

__global__ __launch_bounds__(128, 1)
void header80_pow_warp_pair128_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    DeviceShareResult* __restrict__ result,
    std::size_t count) {
    __shared__ WarpPair128Scratch scratch[2];

    const unsigned int tid = static_cast<unsigned int>(threadIdx.x);
    const unsigned int warp = tid >> 5U;
    const unsigned int lane = tid & 31U;
    const unsigned int pair = warp >> 1U;
    const bool owner = (warp & 1U) == 0U;
    const std::size_t owner_local = static_cast<std::size_t>(pair) * 32U + lane;
    const std::size_t index = static_cast<std::size_t>(blockIdx.x) * 64U + owner_local;
    const bool active = owner && index < count;
    const std::uint32_t nonce = first_nonce + static_cast<std::uint32_t>(active ? index : 0U);

    std::uint32_t first_pass[8]{};
    std::uint32_t mixed[8]{};
    std::uint32_t final_hash[8]{};
    if (active) blake3_header80_words(nonce, first_pass);

    warp_pair128_hoohash_mix_words(
        matrix, scaled_nibble_table, byte_swap32(nonce), first_pass,
        mixed, owner, active, lane, pair, scratch);

    if (!active) return;
    blake3_32_words(mixed, final_hash);
    if (!hash_words_meet_target(final_hash)) return;
    if (atomicCAS(&result->found, 0U, 1U) == 0U) {
        result->nonce = nonce;
        #pragma unroll
        for (int i = 0; i < 8; ++i) result->hash_words[i] = final_hash[i];
    }
}
