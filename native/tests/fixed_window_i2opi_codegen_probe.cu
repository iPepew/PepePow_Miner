#include <cstdint>
#include <cuda_runtime.h>

// Isolated sm_70 codegen probe for the exact fixed limbs 15..17 used by
// libdevice's high-range 2/pi convolution on the measured HooHash domain.
// This is not wired into consensus code.
struct U256 {
    std::uint64_t w0, w1, w2, w3;
};

__device__ __noinline__ U256 fixed_window_mul3(std::uint64_t mantissa) {
    constexpr std::uint64_t c0 = 0xdb6295993c439041ULL;
    constexpr std::uint64_t c1 = 0xfc2757d1f534ddc0ULL;
    constexpr std::uint64_t c2 = 0xa2f9836e4e441529ULL;

    const std::uint64_t lo0 = mantissa * c0;
    const std::uint64_t hi0 = __umul64hi(mantissa, c0);
    const std::uint64_t lo1 = mantissa * c1;
    const std::uint64_t hi1 = __umul64hi(mantissa, c1);
    const std::uint64_t lo2 = mantissa * c2;
    const std::uint64_t hi2 = __umul64hi(mantissa, c2);

    const std::uint64_t w1 = hi0 + lo1;
    const std::uint64_t carry1 = w1 < hi0;
    const std::uint64_t mid = hi1 + lo2;
    const std::uint64_t carry2a = mid < hi1;
    const std::uint64_t w2 = mid + carry1;
    const std::uint64_t carry2b = w2 < mid;
    return U256{lo0, w1, w2, hi2 + carry2a + carry2b};
}

extern "C" __global__ void fixed_window_probe(
    const std::uint64_t* input, U256* output, int count) {
    const int i = int(blockIdx.x * blockDim.x + threadIdx.x);
    if (i < count) output[i] = fixed_window_mul3(input[i]);
}
