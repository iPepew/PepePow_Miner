#include <cuda_runtime.h>
#include <cstdint>

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

template<int W>
__device__ __forceinline__ int prefix_chunk(
    const double* __restrict__ scaled,
    const std::uint8_t* __restrict__ nibble,
    int base, double& sum) {
    double c[W];
    #pragma unroll
    for (int i = 0; i < W; ++i) {
        const unsigned int n = nibble[base + i] & 15U;
        c[i] = __ldg(scaled + static_cast<std::size_t>(base + i) * 16U + n);
    }
    int first_cold = W;
    #pragma unroll
    for (int i = 0; i < W; ++i) {
        sum += c[i];
        if (first_cold == W && sw_cold_exact_finite(sum)) first_cold = i + 1;
    }
    return first_cold;
}

template<int W>
__global__ __launch_bounds__(704, 1) void hotrun_prefix_probe(
    const double* __restrict__ scaled,
    const std::uint8_t* __restrict__ nibble,
    double* __restrict__ output) {
    const int tid = static_cast<int>(blockIdx.x * blockDim.x + threadIdx.x);
    const int base = (tid & 255) * 64;
    double sum = static_cast<double>(tid & 1023) * 0.125;
    int fallback = 0;
    #pragma unroll 1
    for (int col = 0; col < 64; col += W) {
        const int first_cold = prefix_chunk<W>(scaled, nibble, base + col, sum);
        fallback += (first_cold != W);
    }
    output[tid] = sum + static_cast<double>(fallback);
}

template __global__ void hotrun_prefix_probe<4>(const double*, const std::uint8_t*, double*);
template __global__ void hotrun_prefix_probe<8>(const double*, const std::uint8_t*, double*);
template __global__ void hotrun_prefix_probe<16>(const double*, const std::uint8_t*, double*);
