#include <cstdint>
#include <cuda_runtime.h>

// Isolated sm_70 codegen probe. It computes only the two values consumed by
// libdevice after the fixed 2/pi convolution: quadrant and the full signed
// 128-bit fractional remainder consumed by downstream normalization.
// It is intentionally not connected to consensus code.
struct Projection {
    std::uint64_t quadrant;
    std::uint64_t fraction_high;
    std::uint64_t fraction_low;
};

__device__ __forceinline__ Projection demand_sliced_projection(
    std::uint64_t bits) {
    constexpr std::uint64_t c0 = 0xdb6295993c439041ULL;
    constexpr std::uint64_t c1 = 0xfc2757d1f534ddc0ULL;
    constexpr std::uint64_t c2 = 0xa2f9836e4e441529ULL;

    const std::uint64_t mantissa = (bits << 11) | (1ULL << 63);

    // low64(c0*M) is dead. The remaining recurrence retains every carry.
    const std::uint64_t carry0 = __umul64hi(c0, mantissa);
    const std::uint64_t lo1 = c1 * mantissa;
    const std::uint64_t sum1 = lo1 + carry0;
    const std::uint64_t carry1 =
        __umul64hi(c1, mantissa) + static_cast<std::uint64_t>(sum1 < lo1);
    const std::uint64_t lo2 = c2 * mantissa;
    const std::uint64_t sum2 = lo2 + carry1;
    std::uint64_t high =
        __umul64hi(c2, mantissa) + static_cast<std::uint64_t>(sum2 < lo2);

    const unsigned shift =
        static_cast<unsigned>(((bits >> 52) & 0x7ffULL) - 1024ULL) & 63U;
    std::uint64_t shifted_low = sum2;
    if (shift != 0U) {
        high = (high << shift) | (sum2 >> (64U - shift));
        shifted_low = sum2 << shift;
    }

    const std::uint64_t round_bit = (high >> 61) & 1ULL;
    const std::uint64_t quadrant = (high >> 62) + round_bit;
    std::uint64_t fraction_high = (high << 2) | (shifted_low >> 62);
    std::uint64_t fraction_low = shifted_low << 2;
    if (round_bit != 0ULL) {
        const std::uint64_t old_low = fraction_low;
        fraction_low = 0ULL - fraction_low;
        fraction_high = 0ULL - fraction_high - static_cast<std::uint64_t>(old_low != 0ULL);
    }
    return Projection{quadrant, fraction_high, fraction_low};
}

extern "C" __global__ void demand_sliced_empty(
    const std::uint64_t* input, Projection* output, int count) {
    const int i = int(blockIdx.x * blockDim.x + threadIdx.x);
    if (i < count) output[i] = Projection{input[i], 0, 0};
}

extern "C" __global__ void demand_sliced_probe(
    const std::uint64_t* input, Projection* output, int count) {
    const int i = int(blockIdx.x * blockDim.x + threadIdx.x);
    if (i < count) output[i] = demand_sliced_projection(input[i]);
}
