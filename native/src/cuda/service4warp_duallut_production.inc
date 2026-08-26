// Architecture candidate: preserve the verified 704-thread/128-worker service
// topology, but replace expensive exp/sincos and sin^2 cold tasks with the
// proven dual-LUT approximation. Consensus safety is maintained by an error
// interval after every cell and exact replay of only the ambiguous 64-cell row.

namespace {

struct ColdServiceScratchLut {
    unsigned int task_count;
    double task_x[PEPEPOW_CUDA_THREADS];
    double task_value[PEPEPOW_CUDA_THREADS];
    double task_result[PEPEPOW_CUDA_THREADS];
    double task_error[PEPEPOW_CUDA_THREADS];
    unsigned int task_owner[PEPEPOW_CUDA_THREADS];
};

__device__ __forceinline__ bool service4warp_lut_nonlinear(
    double x,
    const double* __restrict__ exp_lut,
    const double* __restrict__ sin2_lut,
    double& out,
    double& abs_error) {
    const double one_base = x * kTransformMultiplier * 0.125;
    const HooHashSelectorParts selector = decode_selector_parts(one_base);
    const double two = selector.two;
    double y;
    if (two < 0.25) y = x + (1.0 + two);
    else if (two < 0.50) y = x - (1.0 + two);
    else if (two < 0.75) y = x * (1.0 + two);
    else y = x / (1.0 + two);

    if (selector.one_region == 0U) {
        if (pepepow::cuda_guarded_lut::exp_sincos_approx(
                y, exp_lut, out, abs_error)) {
            return true;
        }
    } else if (selector.one_region == 1U) {
        if (y == kPi / 2.0 || y == 3.0 * kPi / 2.0) {
            out = 0.0;
            abs_error = 0.0;
            return true;
        }
        if (pepepow::cuda_guarded_lut::sin2_approx(
                y, sin2_lut, out, abs_error)) {
            return true;
        }
    } else {
        out = 1.0 / sqrt(fabs(y) + 1.0);
        abs_error = 0.0;
        return true;
    }

    // Reducer outside its proven domain: use the exact consensus path.
    out = safe_nonlinear(x);
    abs_error = 0.0;
    return false;
}

__device__ __forceinline__ bool service4warp_same_sw_interval(
    double sum, double radius) {
    const double lo = fmax(0.0, sum - radius);
    const double hi = sum + radius;
    HooHashSwState lo_sw = initial_sw_state();
    HooHashSwState hi_sw = initial_sw_state();
    update_sw_state(lo_sw, lo);
    update_sw_state(hi_sw, hi);
    return sw_state_is_cold(lo_sw) == sw_state_is_cold(hi_sw);
}

__device__ __forceinline__ bool service4warp_same_integer_interval(
    double sum, double radius) {
    const double lo = fmax(0.0, sum - radius);
    const double hi = sum + radius;
    return positive_double_to_u64_rz(lo) == positive_double_to_u64_rz(hi);
}

__device__ __forceinline__ void service_accumulate_lut(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    const double* __restrict__ exp_lut,
    const double* __restrict__ sin2_lut,
    int cell_index, std::uint32_t nibble, double value,
    double hash_mod, double nonce_mod, double& sum, HooHashSwState& sw,
    double& radius, bool& ambiguous,
    bool active, ColdServiceScratchLut& scratch) {
    const bool cold = active && sw_state_is_cold(sw);
    const bool task = cold && nibble != 0U;

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

    const unsigned int lane = static_cast<unsigned int>(threadIdx.x) & 31U;
    const unsigned int warp_mask = __activemask();
    const unsigned int task_mask = __ballot_sync(warp_mask, task);
    unsigned int slot = 0U;
    if (task_mask != 0U) {
        const int leader = __ffs(static_cast<int>(task_mask)) - 1;
        unsigned int base = 0U;
        if (static_cast<int>(lane) == leader) {
            base = atomicAdd(&scratch.task_count,
                             static_cast<unsigned int>(__popc(task_mask)));
        }
        base = __shfl_sync(warp_mask, base, leader);
        const unsigned int lower_mask =
            lane == 0U ? 0U : ((1U << lane) - 1U);
        slot = base + static_cast<unsigned int>(
            __popc(task_mask & lower_mask));
        if (task) {
            scratch.task_x[slot] = task_x;
            scratch.task_value[slot] = value;
            scratch.task_owner[slot] = static_cast<unsigned int>(threadIdx.x);
        }
    }

    __syncthreads();
    const unsigned int task_count = scratch.task_count;
    constexpr unsigned int kServiceThreads = 128U;
    if (static_cast<unsigned int>(threadIdx.x) < kServiceThreads) {
        for (unsigned int task_index = static_cast<unsigned int>(threadIdx.x);
             task_index < task_count; task_index += kServiceThreads) {
            double nonlinear_value = 0.0;
            double nonlinear_error = 0.0;
            service4warp_lut_nonlinear(
                scratch.task_x[task_index], exp_lut, sin2_lut,
                nonlinear_value, nonlinear_error);
            const unsigned int owner = scratch.task_owner[task_index];
            const double scale = scratch.task_value[task_index] * 1234.0;
            scratch.task_result[owner] = nonlinear_value * scale;
            scratch.task_error[owner] = nonlinear_error * fabs(scale);
        }
    }
    if (threadIdx.x == 0U) scratch.task_count = 0U;
    __syncthreads();

    if (active) {
        if (cold) {
            if (nibble != 0U) {
                sum += scratch.task_result[threadIdx.x];
                radius += scratch.task_error[threadIdx.x];
            }
        } else {
            sum += warm_contribution;
        }
        if (!service4warp_same_sw_interval(sum, radius)) ambiguous = true;
        update_sw_state(sw, sum);
    }
}

__device__ __forceinline__ double matrix_row_service_lut(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    const double* __restrict__ exp_lut,
    const double* __restrict__ sin2_lut,
    int row, const std::uint32_t first_pass[8], double hash_mod_fp64,
    double nonce_mod, HooHashSwState& sw, bool active,
    ColdServiceScratchLut& scratch) {
    const HooHashSwState sw_checkpoint = sw;
    double sum = 0.0;
    double radius = 0.0;
    bool ambiguous = false;
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
            service_accumulate_lut(
                matrix, scaled_nibble_table, exp_lut, sin2_lut,
                high_cell, high_nibble, nibble_to_double(high_nibble),
                hash_mod_fp64, nonce_mod, sum, sw, radius, ambiguous,
                active, scratch);
            service_accumulate_lut(
                matrix, scaled_nibble_table, exp_lut, sin2_lut,
                high_cell + 1, low_nibble, nibble_to_double(low_nibble),
                hash_mod_fp64, nonce_mod, sum, sw, radius, ambiguous,
                active, scratch);
        }
    }

    // If the approximation could have changed any dependent sw decision or
    // the row integer, discard the approximate state and replay this row with
    // the exact consensus implementation before the next row begins.
    if (active && (ambiguous || !service4warp_same_integer_interval(sum, radius))) {
        HooHashSwState exact_sw = sw_checkpoint;
        const double exact_sum = matrix_row(
            matrix, scaled_nibble_table, row, first_pass,
            hash_mod_fp64, nonce_mod, exact_sw);
        sw = exact_sw;
        return exact_sum;
    }
    return sum;
}

__device__ __forceinline__ void hoohash_mix_words_service_lut(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    const double* __restrict__ exp_lut,
    const double* __restrict__ sin2_lut,
    std::uint32_t mix_nonce, const std::uint32_t first_pass[8],
    std::uint32_t mixed[8], bool active, ColdServiceScratchLut& scratch) {
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
        const double even_sum = matrix_row_service_lut(
            matrix, scaled_nibble_table, exp_lut, sin2_lut,
            pair * 2, first_pass, hash_mod_fp64, nonce_mod,
            sw, active, scratch);
        const double odd_sum = matrix_row_service_lut(
            matrix, scaled_nibble_table, exp_lut, sin2_lut,
            pair * 2 + 1, first_pass, hash_mod_fp64, nonce_mod,
            sw, active, scratch);
        if (active) {
            const std::uint64_t combined =
                positive_double_to_u64_rz(even_sum) +
                positive_double_to_u64_rz(odd_sum);
            const std::uint32_t shift = static_cast<std::uint32_t>((pair & 3) * 8);
            mixed[pair >> 2] ^=
                static_cast<std::uint32_t>(combined & 0xffU) << shift;
        }
    }
}

__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void header80_pow_service4warp_duallut_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    const double* __restrict__ exp_lut,
    const double* __restrict__ sin2_lut,
    DeviceShareResult* __restrict__ result,
    std::size_t count) {
    __shared__ ColdServiceScratchLut scratch;
    if (threadIdx.x == 0U) scratch.task_count = 0U;
    __syncthreads();

    const std::size_t index =
        static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    const bool active = index < count;
    const std::uint32_t nonce =
        first_nonce + static_cast<std::uint32_t>(active ? index : 0U);

    std::uint32_t first_pass[8]{};
    std::uint32_t mixed[8]{};
    std::uint32_t final_hash[8]{};
    if (active) blake3_header80_words(nonce, first_pass);

    hoohash_mix_words_service_lut(
        matrix, scaled_nibble_table, exp_lut, sin2_lut,
        byte_swap32(nonce), first_pass, mixed, active, scratch);

    if (!active) return;
    blake3_32_words(mixed, final_hash);
    if (!hash_words_meet_target(final_hash)) return;
    if (atomicCAS(&result->found, 0U, 1U) == 0U) {
        result->nonce = nonce;
        #pragma unroll
        for (int i = 0; i < 8; ++i) result->hash_words[i] = final_hash[i];
    }
}

} // namespace
