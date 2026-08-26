#if PEPEPOW_CUDA_GUARDED_LUT

using namespace cuda_guarded_lut;

__device__ __forceinline__ bool guarded_classify_sw_prod(
    double sum, double error, bool& cold) {
    const double lo = sum - error;
    const double hi = sum + error;
    if (lo < 0.0) return false;
    const std::uint64_t qlo = positive_double_to_u64_rz(lo * (1.0 / 1024.0));
    const std::uint64_t qhi = positive_double_to_u64_rz(hi * (1.0 / 1024.0));
    if (qlo != qhi) return false;
    const bool lo_cold = positive_fraction_div1024_le_002_finite(lo);
    const bool hi_cold = positive_fraction_div1024_le_002_finite(hi);
    if (lo_cold != hi_cold) return false;
    cold = lo_cold;
    return true;
}

__device__ __forceinline__ bool guarded_row_integer_safe_prod(
    double sum, double error) {
    const double lo = sum - error;
    const double hi = sum + error;
    if (lo < 0.0) return false;
    return positive_double_to_u64_rz(lo) == positive_double_to_u64_rz(hi);
}

__device__ __forceinline__ bool guarded_nonlinear_value_prod(
    double x,
    const double* __restrict__ exp_lut,
    const double* __restrict__ sin2_lut,
    double& value,
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
        return exp_sincos_approx(y, exp_lut, value, abs_error);
    }
    if (selector.one_region == 1U) {
        if (y == kPi / 2.0 || y == 3.0 * kPi / 2.0) {
            value = 0.0;
            abs_error = 0.0;
            return true;
        }
        return sin2_approx(y, sin2_lut, value, abs_error);
    }

    value = 1.0 / sqrt(fabs(y) + 1.0);
    abs_error = 0.0;
    return true;
}

__device__ __noinline__ double guarded_row_exact_fallback_prod(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    int row,
    const std::uint32_t first_pass[8],
    double hash_mod_fp64,
    double nonce_mod,
    HooHashSwState checkpoint_sw,
    HooHashSwState& out_sw) {
    out_sw = checkpoint_sw;
    return matrix_row(matrix, scaled_nibble_table, row, first_pass,
                      hash_mod_fp64, nonce_mod, out_sw);
}

__device__ __forceinline__ double guarded_matrix_row_prod(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    const double* __restrict__ exp_lut,
    const double* __restrict__ sin2_lut,
    int row,
    const std::uint32_t first_pass[8],
    double hash_mod_fp64,
    double nonce_mod,
    HooHashSwState& sw) {
    const HooHashSwState checkpoint_sw = sw;
    bool cold = sw_state_is_cold(sw);
    double sum = 0.0;
    double error = 0.0;
    const int row_offset = row * 64;

    #pragma unroll 1
    for (int word_index = 0; word_index < 8; ++word_index) {
        const std::uint32_t packed_word = first_pass[word_index];
        #pragma unroll
        for (int byte_in_word = 0; byte_in_word < 4; ++byte_in_word) {
            const std::uint8_t packed = static_cast<std::uint8_t>(
                packed_word >> static_cast<unsigned int>(byte_in_word * 8));
            const int high_cell = row_offset + (word_index * 4 + byte_in_word) * 2;
            const std::uint32_t nibbles[2] = {
                static_cast<std::uint32_t>(packed >> 4U),
                static_cast<std::uint32_t>(packed & 0x0fU)};

            #pragma unroll
            for (int half = 0; half < 2; ++half) {
                const std::uint32_t nibble = nibbles[half];
                const double nibble_value = nibble_to_double(nibble);
                if (cold) {
                    if (nibble != 0U) {
                        const int cell_index = high_cell + half;
                        const double x = matrix[cell_index] * hash_mod_fp64 *
                                             nibble_value + nonce_mod;
                        double nonlinear_value = 0.0;
                        double nonlinear_error = 0.0;
                        if (!guarded_nonlinear_value_prod(
                                x, exp_lut, sin2_lut,
                                nonlinear_value, nonlinear_error)) {
                            return guarded_row_exact_fallback_prod(
                                matrix, scaled_nibble_table, row, first_pass,
                                hash_mod_fp64, nonce_mod, checkpoint_sw, sw);
                        }
                        const double scale = nibble_value * 1234.0;
                        sum = fma(nonlinear_value, scale, sum);
                        error += nonlinear_error * fabs(scale);
                    }
                } else {
                    const int cell_index = high_cell + half;
#if PEPEPOW_CUDA_SCALED_NIBBLE_TABLE
                    sum += __ldg(scaled_nibble_table +
                                 static_cast<std::size_t>(cell_index) * 16U + nibble);
#elif PEPEPOW_CUDA_SCALED_MATRIX
                    sum += kHeader80ScaledMatrix[cell_index] * nibble_value;
#else
                    sum += matrix[cell_index] * 0.0001 * nibble_value;
#endif
                }

                bool next_cold = false;
                if (!guarded_classify_sw_prod(sum, error, next_cold)) {
                    return guarded_row_exact_fallback_prod(
                        matrix, scaled_nibble_table, row, first_pass,
                        hash_mod_fp64, nonce_mod, checkpoint_sw, sw);
                }
                cold = next_cold;
            }
        }
    }

    if (!guarded_row_integer_safe_prod(sum, error)) {
        return guarded_row_exact_fallback_prod(
            matrix, scaled_nibble_table, row, first_pass,
            hash_mod_fp64, nonce_mod, checkpoint_sw, sw);
    }

    sw = cold;
    return sum;
}

__device__ __forceinline__ void hoohash_mix_words_guarded(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    const double* __restrict__ exp_lut,
    const double* __restrict__ sin2_lut,
    std::uint32_t mix_nonce,
    const std::uint32_t first_pass[8],
    std::uint32_t mixed[8]) {
    std::uint32_t hash_xor = 0U;
    #pragma unroll
    for (int i = 0; i < 8; ++i) {
        hash_xor ^= first_pass[i];
        mixed[i] = first_pass[i];
    }
    const double hash_mod_fp64 = u32_to_double_exact(byte_swap32(hash_xor));
    const double nonce_mod = u32_to_double_exact(mix_nonce & 0xffU);
    HooHashSwState sw = initial_sw_state();
    #pragma unroll 1
    for (int pair = 0; pair < 32; ++pair) {
        const double even_sum = guarded_matrix_row_prod(
            matrix, scaled_nibble_table, exp_lut, sin2_lut,
            pair * 2, first_pass, hash_mod_fp64, nonce_mod, sw);
        const double odd_sum = guarded_matrix_row_prod(
            matrix, scaled_nibble_table, exp_lut, sin2_lut,
            pair * 2 + 1, first_pass, hash_mod_fp64, nonce_mod, sw);
        const std::uint64_t combined = positive_double_to_u64_rz(even_sum) +
                                       positive_double_to_u64_rz(odd_sum);
        const std::uint32_t shift = static_cast<std::uint32_t>((pair & 3) * 8);
        mixed[pair >> 2] ^= static_cast<std::uint32_t>(combined & 0xffU) << shift;
    }
}

__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void header80_pow_guarded_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    const double* __restrict__ exp_lut,
    const double* __restrict__ sin2_lut,
    DeviceShareResult* __restrict__ result,
    std::size_t count) {
    const std::size_t index =
        static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) return;
    const std::uint32_t nonce = first_nonce + static_cast<std::uint32_t>(index);

    std::uint32_t first_pass[8]{};
    std::uint32_t mixed[8]{};
    std::uint32_t final_hash[8]{};
    blake3_header80_words(nonce, first_pass);
    hoohash_mix_words_guarded(
        matrix, scaled_nibble_table, exp_lut, sin2_lut,
        byte_swap32(nonce), first_pass, mixed);
    blake3_32_words(mixed, final_hash);
    if (!hash_words_meet_target(final_hash)) return;
    if (atomicCAS(&result->found, 0U, 1U) == 0U) {
        result->nonce = nonce;
        #pragma unroll
        for (int i = 0; i < 8; ++i) result->hash_words[i] = final_hash[i];
    }
}

#endif // PEPEPOW_CUDA_GUARDED_LUT
