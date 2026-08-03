    constexpr std::uint64_t kSig033 = 0x00151eb851eb851fULL;
    constexpr std::uint64_t kSig066 = 0x00151eb851eb851fULL;

    unsigned int one_region;
    if (exponent < 1023U) {
        one_region = bits < kBits033 ? 0U : (bits < kBits066 ? 1U : 2U);
    } else {
        const unsigned int integer_bits = exponent - 1023U;
        if (integer_bits >= 52U) {
            one_region = 0U;
        } else {
            const unsigned int fractional_width = 52U - integer_bits;
            const std::uint64_t remainder =
                bits & ((std::uint64_t{1} << fractional_width) - 1ULL);
            if (remainder == 0ULL) one_region = 0U;
            else if ((remainder << (54U - fractional_width)) < kSig033)
                one_region = 0U;
            else if ((remainder << (53U - fractional_width)) < kSig066)
                one_region = 1U;
            else one_region = 2U;
        }
    }

    // one_base is scaled/8. Multiplication by two is exact for the valid
    // normal consensus range, so frac(2*one_base) is exactly frac(scaled/4).
    double two;
    if (exponent == 0U || exponent == 0x7ffU) {
        two = positive_fraction_bits(one_base * 2.0);
    } else {
        const unsigned int doubled_exponent = exponent + 1U;
        if (doubled_exponent < 1023U) {
            const std::uint64_t doubled_bits =
                (bits & kDoubleMantissaMask) |
                (static_cast<std::uint64_t>(doubled_exponent) << 52U);
            two = __longlong_as_double(static_cast<long long>(doubled_bits));
        } else {
            const unsigned int integer_bits = doubled_exponent - 1023U;
            if (integer_bits >= 52U) {
                two = 0.0;
            } else {
                const unsigned int fractional_width = 52U - integer_bits;
                const std::uint64_t fraction =
                    bits & ((std::uint64_t{1} << fractional_width) - 1ULL);
                if (fraction == 0ULL) {
                    two = 0.0;
                } else {
                    const unsigned int msb =
                        63U - static_cast<unsigned int>(__clzll(fraction));
                    const int result_exponent =
                        1023 + static_cast<int>(msb) -
                        static_cast<int>(fractional_width);
                    const std::uint64_t normalized = fraction << (52U - msb);
                    const std::uint64_t result_bits =
                        (static_cast<std::uint64_t>(result_exponent) << 52U) |
                        (normalized & kDoubleMantissaMask);
                    two = __longlong_as_double(static_cast<long long>(result_bits));
                }
            }
        }
    }
    return {one_region, two};
}

__device__ __forceinline__ double nonlinear(double x) {
    const double one_base = x * kTransformMultiplier * 0.125;
    const HooHashSelectorParts selector = decode_selector_parts(one_base);
    const double two = selector.two;
    double y;
    if (two < 0.25) y = x + (1.0 + two);
    else if (two < 0.50) y = x - (1.0 + two);
    else if (two < 0.75) y = x * (1.0 + two);
    else y = x / (1.0 + two);
    if (selector.one_region == 0U) {
        double sine, cosine;
        sincos(y, &sine, &cosine);
        return exp(sine + cosine);
    }
    if (selector.one_region == 1U) {
        if (y == kPi / 2.0 || y == 3.0 * kPi / 2.0) return 0.0;
        const double sine = sin(y);
        return sine * sine;
    }
    return 1.0 / sqrt(fabs(y) + 1.0);
}

__device__ __forceinline__ double safe_nonlinear(double x) {
#if PEPEPOW_CUDA_ASSUME_FINITE
    // HooHash V110 bounds x to roughly 6.5e16: matrix <= 1e6,
    // hash_mod <= UINT32_MAX, nibble <= 15 and nonce_mod <= 255.
    // All selector transforms remain finite; exp receives sin+cos in
    // [-sqrt(2), sqrt(2)]. Therefore the retry loop is unreachable for valid
    // consensus inputs. The guarded reference path remains available to the
    // autotuner and every candidate is CPU/CUDA validated.
    return nonlinear(x);
#else
    double rounds = 1.0;
    double out = nonlinear(x);
    while (isnan(out) || isinf(out)) {
        x *= 0.1;
        if (x <= 1e-13) return 0.0;
        rounds += 1.0;
        out = nonlinear(x);
    }
    return out * rounds;
#endif
}

__device__ __forceinline__ std::uint8_t word_byte(
    const std::uint32_t words[8], int byte_index) {
    const std::uint32_t word = words[byte_index >> 2];
    return static_cast<std::uint8_t>(word >> ((byte_index & 3) * 8));
}

__device__ __forceinline__ void accumulate(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    int cell_index, std::uint32_t nibble, double value,
    double hash_mod, double nonce_mod, double& sum, HooHashSwState& sw) {
    if (sw_state_is_cold(sw)) {
        if (nibble != 0U) {
            const double cell = matrix[cell_index];
            const double x = cell * hash_mod * value + nonce_mod;
            sum += safe_nonlinear(x) * value * 1234.0;
        }
    } else {
#if PEPEPOW_CUDA_SCALED_NIBBLE_TABLE
        // Cell-major layout makes the 32 lanes read from one contiguous
        // 128-byte group. The table value is computed on the host as exactly
        // (matrix[cell] * 0.0001) * nibble, preserving operation order and
        // rounding while replacing a hot FP64 multiply with a cached load.
        sum += __ldg(scaled_nibble_table +
                     static_cast<std::size_t>(cell_index) * 16U + nibble);
#elif PEPEPOW_CUDA_SCALED_MATRIX
        sum += kHeader80ScaledMatrix[cell_index] * value;
#else
        sum += matrix[cell_index] * 0.0001 * value;
#endif
    }
    update_sw_state(sw, sum);
}

__device__ __forceinline__ double matrix_row(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    int row, const std::uint32_t first_pass[8], double hash_mod_fp64,
    double nonce_mod, HooHashSwState& sw) {
    double sum = 0.0;
    const int row_offset = row * 64;
