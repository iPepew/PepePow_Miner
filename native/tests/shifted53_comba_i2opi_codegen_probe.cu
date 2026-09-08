#include <cstdint>
#include <cuda_runtime.h>

struct U256 {
    std::uint64_t w0, w1, w2, w3;
};

struct U128Pair {
    std::uint64_t lo, hi;
};

// Exact 53x64 multiplication. Splitting N into 32+21 bits exposes the
// narrower variable operand to sm_70 codegen while retaining every carry.
__device__ __forceinline__ U128Pair mul53x64(
    std::uint64_t n, std::uint64_t c) {
    const std::uint32_t n0 = static_cast<std::uint32_t>(n);
    const std::uint32_t n1 = static_cast<std::uint32_t>(n >> 32);
    const std::uint32_t c0 = static_cast<std::uint32_t>(c);
    const std::uint32_t c1 = static_cast<std::uint32_t>(c >> 32);

    const std::uint64_t p00 = std::uint64_t(n0) * c0;
    const std::uint64_t p01 = std::uint64_t(n0) * c1;
    const std::uint64_t p10 = std::uint64_t(n1) * c0;
    const std::uint64_t p11 = std::uint64_t(n1) * c1;

    const std::uint64_t a = p00 + (p01 << 32);
    const std::uint64_t ca = a < p00;
    const std::uint64_t lo = a + (p10 << 32);
    const std::uint64_t cb = lo < a;
    const std::uint64_t hi =
        p11 + (p01 >> 32) + (p10 >> 32) + ca + cb;
    return U128Pair{lo, hi};
}

__device__ __noinline__ U256 shifted53_comba_mul3(std::uint64_t n) {
    constexpr std::uint64_t c0 = 0xdb6295993c439041ULL;
    constexpr std::uint64_t c1 = 0xfc2757d1f534ddc0ULL;
    constexpr std::uint64_t c2 = 0xa2f9836e4e441529ULL;

    const U128Pair q0 = mul53x64(n, c0);
    const U128Pair q1 = mul53x64(n, c1);
    const U128Pair q2 = mul53x64(n, c2);

    const std::uint64_t p1 = q0.hi + q1.lo;
    const std::uint64_t carry1 = p1 < q0.hi;
    const std::uint64_t mid = q1.hi + q2.lo;
    const std::uint64_t carry2a = mid < q1.hi;
    const std::uint64_t p2 = mid + carry1;
    const std::uint64_t carry2b = p2 < mid;
    const std::uint64_t p3 = q2.hi + carry2a + carry2b;

    // M=N<<11, therefore M*C=(N*C)<<11. N<2^53 and C<2^192,
    // so the shifted product fits exactly in 256 bits.
    return U256{
        q0.lo << 11,
        (p1 << 11) | (q0.lo >> 53),
        (p2 << 11) | (p1 >> 53),
        (p3 << 11) | (p2 >> 53)
    };
}

extern "C" __global__ void shifted53_empty(
    const std::uint64_t* input, U256* output, int count) {
    const int i = int(blockIdx.x * blockDim.x + threadIdx.x);
    if (i < count) output[i] = U256{input[i], 0, 0, 0};
}

extern "C" __global__ void shifted53_probe(
    const std::uint64_t* input, U256* output, int count) {
    const int i = int(blockIdx.x * blockDim.x + threadIdx.x);
    if (i < count) output[i] = shifted53_comba_mul3(input[i]);
}
