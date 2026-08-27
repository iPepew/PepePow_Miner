#include <cuda_runtime.h>
#include <cstdint>
#include <cmath>

__device__ __forceinline__ bool sw_cold_exact_finite(double value) {
    const std::uint64_t bits = static_cast<std::uint64_t>(__double_as_longlong(value));
    constexpr std::uint64_t kScaledThresholdBits = 0x40347ae147ae147bULL;
    constexpr std::uint64_t kThresholdSignificand = 5764607523034235ULL;
    if (bits <= kScaledThresholdBits) return true;
    const unsigned int exponent = static_cast<unsigned int>((bits >> 52U) & 0x7ffULL);
    if (exponent < 1033U) return false;
    const unsigned int integer_bits = exponent - 1033U;
    if (integer_bits >= 52U) return true;
    const unsigned int fractional_width = 52U - integer_bits;
    const std::uint64_t remainder = bits & ((1ULL << fractional_width) - 1ULL);
    return (remainder << (58U - fractional_width)) <= kThresholdSignificand;
}

__device__ __forceinline__ double exact_cold(double x) {
    const double two = x - floor(x);
    double y;
    if (two < 0.25) y = x + (1.0 + two);
    else if (two < 0.50) y = x - (1.0 + two);
    else if (two < 0.75) y = x * (1.0 + two);
    else y = x / (1.0 + two);
    const double one = x * 0.125 - floor(x * 0.125);
    if (one < 0.33) {
        double s, c; sincos(y, &s, &c); return exp(s + c);
    }
    if (one < 0.66) { const double s = sin(y); return s * s; }
    return 1.0 / sqrt(fabs(y) + 1.0);
}

__global__ __launch_bounds__(704,1) void hotrun8_exact_fallback_probe(
    const double* __restrict__ scaled,
    const double* __restrict__ matrix,
    const std::uint8_t* __restrict__ nibble,
    double hash_mod,
    double nonce_mod,
    double* __restrict__ output) {
    const int tid = static_cast<int>(blockIdx.x * blockDim.x + threadIdx.x);
    const int row = tid & 63;
    const int base = row * 64;
    double sum = 0.0;

    #pragma unroll 1
    for (int col = 0; col < 64;) {
        if (!sw_cold_exact_finite(sum) && col <= 56) {
            double c[8];
            #pragma unroll
            for (int i = 0; i < 8; ++i) {
                const unsigned int n = nibble[base + col + i] & 15U;
                c[i] = __ldg(scaled + static_cast<std::size_t>(base + col + i) * 16U + n);
            }
            int consumed = 0;
            #pragma unroll
            for (int i = 0; i < 8; ++i) {
                const double next = sum + c[i];
                if (sw_cold_exact_finite(next)) break;
                sum = next;
                consumed = i + 1;
            }
            if (consumed != 0) { col += consumed; continue; }
        }

        const unsigned int n = nibble[base + col] & 15U;
        if (sw_cold_exact_finite(sum)) {
            if (n != 0U) {
                const double value = static_cast<double>(n);
                const double x = matrix[base + col] * hash_mod * value + nonce_mod;
                sum += exact_cold(x) * value * 1234.0;
            }
        } else {
            sum += __ldg(scaled + static_cast<std::size_t>(base + col) * 16U + n);
        }
        ++col;
    }
    output[tid] = sum;
}
