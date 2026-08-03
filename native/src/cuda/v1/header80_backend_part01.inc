    host_compress(kHostIv.data(), block, 64, kChunkStart, compressed);

    std::array<std::uint32_t, 8> midstate{};
    std::copy_n(compressed, 8, midstate.begin());
    return midstate;
}

__device__ __forceinline__ std::uint32_t rotr32(std::uint32_t value, int bits) {
    return __funnelshift_r(value, value, bits);
}

__device__ __forceinline__ std::uint32_t byte_swap32(std::uint32_t value) {
    return __byte_perm(value, 0U, 0x0123U);
}


constexpr std::uint64_t kDoubleMantissaMask = (std::uint64_t{1} << 52U) - 1U;

__device__ __forceinline__ double u32_to_double_exact(std::uint32_t value) {
#if PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS
    if (value == 0U) return 0.0;
    const unsigned int msb = 31U - static_cast<unsigned int>(__clz(value));
    const std::uint64_t normalized = static_cast<std::uint64_t>(value) << (52U - msb);
    const std::uint64_t bits =
        (static_cast<std::uint64_t>(1023U + msb) << 52U) |
        (normalized & kDoubleMantissaMask);
    return __longlong_as_double(static_cast<long long>(bits));
#else
    return static_cast<double>(value);
#endif
}

__device__ __forceinline__ double nibble_to_double(std::uint32_t value) {
#if PEPEPOW_CUDA_NIBBLE_TABLE
    return kHeader80NibbleFp64[value & 0x0fU];
#else
    return u32_to_double_exact(value & 0x0fU);
#endif
}

__device__ __forceinline__ double positive_fraction_bits(double value) {
    const std::uint64_t bits = static_cast<std::uint64_t>(__double_as_longlong(value));
    const unsigned int exponent = static_cast<unsigned int>((bits >> 52U) & 0x7ffU);
    if (exponent < 1023U) return value;
    const unsigned int integer_bits = exponent - 1023U;
    if (integer_bits >= 52U) return 0.0;
    const unsigned int fractional_width = 52U - integer_bits;
    const std::uint64_t fraction_mask =
        (std::uint64_t{1} << fractional_width) - std::uint64_t{1};
    const std::uint64_t fraction = bits & fraction_mask;
    if (fraction == 0U) return 0.0;
    const unsigned int msb = 63U - static_cast<unsigned int>(__clzll(fraction));
    const int result_exponent = 1023 + static_cast<int>(msb) -
                                static_cast<int>(fractional_width);
    const std::uint64_t normalized = fraction << (52U - msb);
    const std::uint64_t result_bits =
        (static_cast<std::uint64_t>(result_exponent) << 52U) |
        (normalized & kDoubleMantissaMask);
    return __longlong_as_double(static_cast<long long>(result_bits));
}

__device__ __forceinline__ double positive_fraction_div1024_bits(double value) {
#if PEPEPOW_CUDA_BIT_SW_FRACTION
    if (value == 0.0) return 0.0;
    const std::uint64_t bits = static_cast<std::uint64_t>(__double_as_longlong(value));
    const unsigned int exponent = static_cast<unsigned int>((bits >> 52U) & 0x7ffU);
    if (exponent == 0U || exponent == 0x7ffU || exponent <= 10U) {
        return positive_fraction_bits(value * 0x1.0p-10);
    }
    const unsigned int scaled_exponent = exponent - 10U;
    if (scaled_exponent < 1023U) {
        const std::uint64_t scaled_bits =
            (bits & kDoubleMantissaMask) |
            (static_cast<std::uint64_t>(scaled_exponent) << 52U);
        return __longlong_as_double(static_cast<long long>(scaled_bits));
    }
    const unsigned int integer_bits = scaled_exponent - 1023U;
    if (integer_bits >= 52U) return 0.0;
    const unsigned int fractional_width = 52U - integer_bits;
    const std::uint64_t fraction_mask =
        (std::uint64_t{1} << fractional_width) - std::uint64_t{1};
    const std::uint64_t fraction = bits & fraction_mask;
    if (fraction == 0U) return 0.0;
    const unsigned int msb = 63U - static_cast<unsigned int>(__clzll(fraction));
    const int result_exponent = 1023 + static_cast<int>(msb) -
                                static_cast<int>(fractional_width);
    const std::uint64_t normalized = fraction << (52U - msb);
    const std::uint64_t result_bits =
        (static_cast<std::uint64_t>(result_exponent) << 52U) |
        (normalized & kDoubleMantissaMask);
    return __longlong_as_double(static_cast<long long>(result_bits));
#else
    return positive_fraction(value / 1024.0);
#endif
}

__device__ __forceinline__ bool
positive_fraction_div1024_le_002_exact(double value) {
    const std::uint64_t bits =
        static_cast<std::uint64_t>(__double_as_longlong(value));
    constexpr std::uint64_t kSignMask = 0x8000000000000000ULL;
    constexpr std::uint64_t kScaledThresholdBits = 0x40347ae147ae147bULL;
    constexpr std::uint64_t kThresholdSignificand = 5764607523034235ULL;

    const unsigned int exponent =
        static_cast<unsigned int>((bits >> 52U) & 0x7ffULL);
    if ((bits & kSignMask) != 0ULL || exponent == 0x7ffU) {
        return positive_fraction_div1024_bits(value) <= 0.02;
    }
    if (bits <= kScaledThresholdBits) return true;
    if (exponent < 1033U) return false;

    const unsigned int integer_bits = exponent - 1033U;
    if (integer_bits >= 52U) return true;
    const unsigned int fractional_width = 52U - integer_bits;
    const std::uint64_t remainder_mask =
        (1ULL << fractional_width) - 1ULL;
    const std::uint64_t remainder = bits & remainder_mask;
    return (remainder << (58U - fractional_width)) <=
           kThresholdSignificand;
}

__device__ __forceinline__ bool
positive_fraction_div1024_le_002_finite(double value) {
    const std::uint64_t bits =
        static_cast<std::uint64_t>(__double_as_longlong(value));
    constexpr std::uint64_t kScaledThresholdBits = 0x40347ae147ae147bULL;
    constexpr std::uint64_t kThresholdSignificand = 5764607523034235ULL;

    if (bits <= kScaledThresholdBits) return true;
    const unsigned int exponent =
        static_cast<unsigned int>((bits >> 52U) & 0x7ffULL);
    if (exponent < 1033U) return false;

    const unsigned int integer_bits = exponent - 1033U;
    if (integer_bits >= 52U) return true;
    const unsigned int fractional_width = 52U - integer_bits;
    const std::uint64_t remainder =
