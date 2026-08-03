from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: prepare-v081-coldpath-source.py SOURCE MODE")

path = Path(sys.argv[1])
mode = sys.argv[2]
text = path.read_text(encoding="utf-8")

region_old = r'''__device__ __forceinline__ unsigned int fraction_region_033_066(double value) {
    // Consensus inputs are positive and finite. Compare the fractional
    // remainder directly with the exact binary64 encodings of 0.33 and 0.66.
    // This removes one full fraction-normalization path without changing the
    // branch selected by the reference implementation.
    const std::uint64_t bits =
        static_cast<std::uint64_t>(__double_as_longlong(value));
    const unsigned int exponent =
        static_cast<unsigned int>((bits >> 52U) & 0x7ffULL);
    constexpr std::uint64_t kBits033 = 0x3fd51eb851eb851fULL;
    constexpr std::uint64_t kBits066 = 0x3fe51eb851eb851fULL;
    constexpr std::uint64_t kSig033 = 0x00151eb851eb851fULL;
    constexpr std::uint64_t kSig066 = 0x00151eb851eb851fULL;

    if (exponent < 1023U) {
        if (bits < kBits033) return 0U;
        if (bits < kBits066) return 1U;
        return 2U;
    }
    const unsigned int integer_bits = exponent - 1023U;
    if (integer_bits >= 52U) return 0U;
    const unsigned int fractional_width = 52U - integer_bits;
    const std::uint64_t remainder =
        bits & ((std::uint64_t{1} << fractional_width) - 1ULL);
    if (remainder == 0ULL) return 0U;
    if ((remainder << (54U - fractional_width)) < kSig033) return 0U;
    if ((remainder << (53U - fractional_width)) < kSig066) return 1U;
    return 2U;
}

__device__ __forceinline__ double nonlinear(double x) {
    const double scaled = x * kTransformMultiplier;
    const unsigned int one_region =
        fraction_region_033_066(scaled * 0.125);
    const double two = positive_fraction(scaled * 0.25);
    double y;
    if (two < 0.25) y = x + (1.0 + two);
    else if (two < 0.50) y = x - (1.0 + two);
    else if (two < 0.75) y = x * (1.0 + two);
    else y = x / (1.0 + two);
    if (one_region == 0U) {
        double sine, cosine;
        sincos(y, &sine, &cosine);
        return exp(sine + cosine);
    }
    if (one_region == 1U) {
        if (y == kPi / 2.0 || y == 3.0 * kPi / 2.0) return 0.0;
        const double sine = sin(y);
        return sine * sine;
    }
    return 1.0 / sqrt(fabs(y) + 1.0);
}'''

region_new = r'''struct HooHashSelectorParts {
    unsigned int one_region;
    double two;
};

__device__ __forceinline__ HooHashSelectorParts decode_selector_parts(
    double one_base) {
    const std::uint64_t bits =
        static_cast<std::uint64_t>(__double_as_longlong(one_base));
    const unsigned int exponent =
        static_cast<unsigned int>((bits >> 52U) & 0x7ffULL);
    constexpr std::uint64_t kBits033 = 0x3fd51eb851eb851fULL;
    constexpr std::uint64_t kBits066 = 0x3fe51eb851eb851fULL;
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
}'''

if "combined" in mode:
    count = text.count(region_old)
    if count != 1:
        raise SystemExit(f"ERROR: selector block count={count}")
    text = text.replace(region_old, region_new, 1)

if "noinline" in mode:
    old = "__device__ __forceinline__ double safe_nonlinear(double x) {"
    new = "__device__ __noinline__ double safe_nonlinear(double x) {"
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"ERROR: safe_nonlinear signature count={count}")
    text = text.replace(old, new, 1)

if "coldcall" in mode:
    accumulate_marker = r'''__device__ __forceinline__ void accumulate(
    const double* __restrict__ matrix,'''
    cold_function = r'''__device__ __noinline__ double cold_contribution(
    double cell, double hash_mod, double value, double nonce_mod) {
    const double x = cell * hash_mod * value + nonce_mod;
    return safe_nonlinear(x) * value * 1234.0;
}

'''
    count = text.count(accumulate_marker)
    if count != 1:
        raise SystemExit(f"ERROR: accumulate marker count={count}")
    text = text.replace(accumulate_marker, cold_function + accumulate_marker, 1)
    old_cold = r'''        if (nibble != 0U) {
            const double cell = matrix[cell_index];
            const double x = cell * hash_mod * value + nonce_mod;
            sum += safe_nonlinear(x) * value * 1234.0;
        }'''
    new_cold = r'''        if (nibble != 0U) {
            const double cell = matrix[cell_index];
            sum += cold_contribution(cell, hash_mod, value, nonce_mod);
        }'''
    count = text.count(old_cold)
    if count != 1:
        raise SystemExit(f"ERROR: cold accumulate block count={count}")
    text = text.replace(old_cold, new_cold, 1)

path.write_text(text, encoding="utf-8")
