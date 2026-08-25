#include "../src/cuda/guarded_lut_primitives.cuh"

// Compile the probe in the same translation unit as the real v2.1 CUDA
// implementation so the fast path uses the production selector, SW state,
// exact conversions and matrix-row fallback helpers.
#define PEPEPOW_CUDA_THREADS 704
#define PEPEPOW_CUDA_MIN_BLOCKS 1
#define PEPEPOW_CUDA_SPLIT_PIPELINE 0
#define PEPEPOW_CUDA_SCALED_MATRIX 1
#define PEPEPOW_CUDA_SCALED_NIBBLE_TABLE 1
#define PEPEPOW_CUDA_ASSUME_FINITE 1
#define PEPEPOW_CUDA_SW_STATE_MODE 3
#include "../src/cuda/header80_backend.cu"

namespace pepepow {
namespace {

using namespace cuda_guarded_lut;

struct GuardedRowProbeOut {
    std::uint64_t row_integer;
    unsigned int final_cold;
    unsigned int fallback;
};

__device__ __forceinline__ bool guarded_classify_sw(
    double sum, double error, bool& cold) {
    const double lo = sum - error;
    const double hi = sum + error;
    if (lo < 0.0) return false;

    // Crossing a 1024 boundary wraps frac(sum/1024), therefore the interval
    // cannot be classified from endpoint predicates alone.
    const std::uint64_t qlo = positive_double_to_u64_rz(lo * (1.0 / 1024.0));
    const std::uint64_t qhi = positive_double_to_u64_rz(hi * (1.0 / 1024.0));
    if (qlo != qhi) return false;

    const bool lo_cold = positive_fraction_div1024_le_002_finite(lo);
    const bool hi_cold = positive_fraction_div1024_le_002_finite(hi);
    if (lo_cold != hi_cold) return false;
    cold = lo_cold;
    return true;
}

__device__ __forceinline__ bool guarded_row_integer_safe(
    double sum, double error, std::uint64_t& integer_value) {
    const double lo = sum - error;
    const double hi = sum + error;
    if (lo < 0.0) return false;
    const std::uint64_t ilo = positive_double_to_u64_rz(lo);
    const std::uint64_t ihi = positive_double_to_u64_rz(hi);
    if (ilo != ihi) return false;
    integer_value = ilo;
    return true;
}

__device__ __forceinline__ bool guarded_nonlinear_value(
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

    // Keep the sqrt branch exact in the first architecture candidate.
    value = 1.0 / sqrt(fabs(y) + 1.0);
    abs_error = 0.0;
    return true;
}

__device__ __noinline__ double guarded_row_exact_fallback(
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

__device__ __forceinline__ double guarded_matrix_row_probe(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    const double* __restrict__ exp_lut,
    const double* __restrict__ sin2_lut,
    int row,
    const std::uint32_t first_pass[8],
    double hash_mod_fp64,
    double nonce_mod,
    HooHashSwState& sw,
    bool& used_fallback) {
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
                        if (!guarded_nonlinear_value(
                                x, exp_lut, sin2_lut,
                                nonlinear_value, nonlinear_error)) {
                            used_fallback = true;
                            return guarded_row_exact_fallback(
                                matrix, scaled_nibble_table, row, first_pass,
                                hash_mod_fp64, nonce_mod, checkpoint_sw, sw);
                        }
                        const double scale = nibble_value * 1234.0;
                        sum = fma(nonlinear_value, scale, sum);
                        error += nonlinear_error * fabs(scale);
                    }
                } else {
                    const int cell_index = high_cell + half;
                    sum += __ldg(scaled_nibble_table +
                                 static_cast<std::size_t>(cell_index) * 16U + nibble);
                }

                bool next_cold = false;
                if (!guarded_classify_sw(sum, error, next_cold)) {
                    used_fallback = true;
                    return guarded_row_exact_fallback(
                        matrix, scaled_nibble_table, row, first_pass,
                        hash_mod_fp64, nonce_mod, checkpoint_sw, sw);
                }
                cold = next_cold;
            }
        }
    }

    std::uint64_t row_integer = 0U;
    if (!guarded_row_integer_safe(sum, error, row_integer)) {
        used_fallback = true;
        return guarded_row_exact_fallback(
            matrix, scaled_nibble_table, row, first_pass,
            hash_mod_fp64, nonce_mod, checkpoint_sw, sw);
    }

    sw = cold;
    // Any representative inside the certified integer interval is safe for
    // the caller's positive_double_to_u64_rz conversion.
    return sum;
}

__global__ __launch_bounds__(704, 1)
void guarded_lut_row_hotpath_compile_probe(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    const double* __restrict__ exp_lut,
    const double* __restrict__ sin2_lut,
    const std::uint32_t* __restrict__ work_words,
    GuardedRowProbeOut* __restrict__ out,
    std::size_t count) {
    const std::size_t index = static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) return;

    std::uint32_t first_pass[8];
    #pragma unroll
    for (int i = 0; i < 8; ++i) first_pass[i] = work_words[index * 8U + i];
    std::uint32_t hash_xor = 0U;
    #pragma unroll
    for (int i = 0; i < 8; ++i) hash_xor ^= first_pass[i];

    const double hash_mod_fp64 = u32_to_double_exact(byte_swap32(hash_xor));
    const double nonce_mod = u32_to_double_exact(static_cast<std::uint32_t>(index) & 0xffU);
    HooHashSwState sw = initial_sw_state();
    bool fallback = false;
    const double sum = guarded_matrix_row_probe(
        matrix, scaled_nibble_table, exp_lut, sin2_lut,
        static_cast<int>(index & 63U), first_pass,
        hash_mod_fp64, nonce_mod, sw, fallback);

    GuardedRowProbeOut r{};
    r.row_integer = positive_double_to_u64_rz(sum);
    r.final_cold = sw_state_is_cold(sw) ? 1U : 0U;
    r.fallback = fallback ? 1U : 0U;
    out[index] = r;
}

} // namespace
} // namespace pepepow
