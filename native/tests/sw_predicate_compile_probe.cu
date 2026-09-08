#include <cuda_runtime.h>
#include <cstddef>
#include <cstdint>

constexpr std::uint64_t kThresholdSignificand = 5764607523034235ULL;

__device__ __noinline__ bool baseline_predicate(double sum) {
    const double scaled = sum * 0x1.0p-10;
    const unsigned long long whole = __double2ull_rd(scaled);
    return (scaled - static_cast<double>(whole)) <= 0.02;
}

template <unsigned int Exponent>
__device__ __forceinline__ bool fixed_exponent_predicate(double sum) {
    static_assert(Exponent >= 1033U && Exponent <= 1084U);
    constexpr unsigned int integer_bits = Exponent - 1033U;
    constexpr unsigned int fractional_width = 52U - integer_bits;
    constexpr std::uint64_t remainder_mask =
        (std::uint64_t{1} << fractional_width) - 1ULL;
    constexpr unsigned int align_shift = 58U - fractional_width;
    const std::uint64_t bits =
        static_cast<std::uint64_t>(__double_as_longlong(sum));
    const std::uint64_t remainder = bits & remainder_mask;
    return (remainder << align_shift) <= kThresholdSignificand;
}

__device__ __noinline__ bool fixed_1037_predicate(double sum) {
    return fixed_exponent_predicate<1037U>(sum);
}

__device__ __noinline__ bool four_bucket_predicate(double sum) {
    const std::uint64_t bits =
        static_cast<std::uint64_t>(__double_as_longlong(sum));
    const unsigned int exponent =
        static_cast<unsigned int>((bits >> 52U) & 0x7ffULL);
    switch (exponent) {
        case 1035U: return fixed_exponent_predicate<1035U>(sum);
        case 1036U: return fixed_exponent_predicate<1036U>(sum);
        case 1037U: return fixed_exponent_predicate<1037U>(sum);
        case 1038U: return fixed_exponent_predicate<1038U>(sum);
        default: return baseline_predicate(sum);
    }
}

extern "C" __global__ void sw_predicate_probe(
    const double* __restrict__ input,
    unsigned int* __restrict__ output,
    std::size_t count) {
    const std::size_t index =
        static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) return;
    const double sum = input[index];
    const unsigned int a = baseline_predicate(sum) ? 1U : 0U;
    const unsigned int b = fixed_1037_predicate(sum) ? 2U : 0U;
    const unsigned int c = four_bucket_predicate(sum) ? 4U : 0U;
    output[index] = a | b | c;
}
