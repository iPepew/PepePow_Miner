from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: prepare-v100-hotloop-source.py SOURCE MODE")

path = Path(sys.argv[1])
mode = sys.argv[2]
text = path.read_text(encoding="utf-8")


def replace_between(source: str, begin: str, end: str, replacement: str, label: str) -> str:
    start = source.find(begin)
    if start < 0:
        raise SystemExit(f"ERROR: {label} begin marker not found")
    stop = source.find(end, start)
    if stop < 0:
        raise SystemExit(f"ERROR: {label} end marker not found")
    return source[:start] + replacement + source[stop:]


if "parity" in mode:
    selector = r'''struct HooHashSelectorParts {
    unsigned int one_region;
    double two;
};

__device__ __forceinline__ HooHashSelectorParts decode_selector_parts(
    double one_base) {
    const std::uint64_t bits =
        static_cast<std::uint64_t>(__double_as_longlong(one_base));
    const unsigned int exponent =
        static_cast<unsigned int>((bits >> 52U) & 0x7ffULL);

    // q is floor(2 * frac(one_base)). It is the highest fractional bit.
    // With two = frac(2 * one_base), the original one thresholds become:
    //   q=0: one < 0.33  <=> two < 0.66
    //   q=1: one < 0.66  <=> two < (2*double(0.66)-1)
    unsigned int q = 0U;
    if (exponent < 1023U) {
        q = bits >= 0x3fe0000000000000ULL ? 1U : 0U;
    } else {
        const unsigned int integer_bits = exponent - 1023U;
        if (integer_bits < 52U) {
            const unsigned int fractional_width = 52U - integer_bits;
            q = static_cast<unsigned int>(
                (bits >> (fractional_width - 1U)) & 1ULL);
        }
    }

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

    unsigned int one_region;
    if (q == 0U) {
        constexpr std::uint64_t kTwoFor033Bits = 0x3fe51eb851eb851fULL;
        const double threshold =
            __longlong_as_double(static_cast<long long>(kTwoFor033Bits));
        one_region = two < threshold ? 0U : 1U;
    } else {
        // Exact binary64 result of 2*double(0.66)-1. It is one ULP above
        // the literal double(0.32), which is required for strict equivalence.
        constexpr std::uint64_t kTwoFor066Bits = 0x3fd47ae147ae147cULL;
        const double threshold =
            __longlong_as_double(static_cast<long long>(kTwoFor066Bits));
        one_region = two < threshold ? 1U : 2U;
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

'''
    text = replace_between(
        text,
        "struct HooHashSelectorParts {",
        "__device__ __forceinline__ double safe_nonlinear",
        selector,
        "selector",
    )


if "sw32" in mode:
    sw32 = r'''__device__ __forceinline__ bool
positive_fraction_div1024_le_002_finite(double value) {
    const std::uint64_t bits =
        static_cast<std::uint64_t>(__double_as_longlong(value));
    constexpr std::uint64_t kScaledThresholdBits = 0x40347ae147ae147bULL;

    // Rows begin close to zero. These two comparisons exactly cover y<1,
    // where frac(value/1024) is simply value/1024.
    if (bits <= kScaledThresholdBits) return true;
    const unsigned int exponent =
        static_cast<unsigned int>((bits >> 52U) & 0x7ffULL);
    if (exponent < 1033U) return false;

    const unsigned int integer_bits = exponent - 1033U;
    if (integer_bits >= 52U) return true;

    // All valid HooHash row sums are far below 2^23. For the hot exponent
    // range 0..12, compare the fractional remainder using only 32-bit ALU
    // operations. This avoids a variable 64-bit mask, shift and comparison
    // on every one of the 4096 cells per nonce.
    if (integer_bits <= 12U) {
        const std::uint32_t high =
            static_cast<std::uint32_t>(bits >> 32U) &
            (0x000fffffU >> integer_bits);
        const std::uint32_t low = static_cast<std::uint32_t>(bits);
        const std::uint32_t threshold_high = 0x000051ebU >> integer_bits;
        const std::uint32_t threshold_low = __funnelshift_r(
            0x851eb851U, 0x000051ebU, integer_bits);
        if (high < threshold_high) return true;
        if (high > threshold_high) return false;
        return low <= threshold_low;
    }

    // Fully generic exact fallback. It is retained for defensive consensus
    // correctness although the bounded HooHash contribution range does not
    // enter this path in normal mining.
    const unsigned int fractional_width = 52U - integer_bits;
    const std::uint64_t remainder =
        bits & ((1ULL << fractional_width) - 1ULL);
    constexpr std::uint64_t kThresholdSignificand = 5764607523034235ULL;
    return (remainder << (58U - fractional_width)) <=
           kThresholdSignificand;
}

'''
    text = replace_between(
        text,
        "__device__ __forceinline__ bool\npositive_fraction_div1024_le_002_finite",
        "#if PEPEPOW_CUDA_SW_STATE_MODE == 0",
        sw32,
        "sw predicate",
    )


if "pointer" in mode:
    pointer_walk = r'''__device__ __forceinline__ void accumulate_pointer(
    const double* __restrict__ matrix_cell,
    const double* __restrict__ scaled_nibble_cell,
    std::uint32_t nibble, double value,
    double hash_mod, double nonce_mod, double& sum, HooHashSwState& sw) {
    const bool cold = sw_state_is_cold(sw);
'''
    if "unlikely" in mode:
        pointer_walk += r'''    if (__builtin_expect(static_cast<int>(cold), 0)) {
'''
    else:
        pointer_walk += r'''    if (cold) {
'''
    pointer_walk += r'''        if (nibble != 0U) {
            const double cell = *matrix_cell;
            const double x = cell * hash_mod * value + nonce_mod;
            sum += safe_nonlinear(x) * value * 1234.0;
        }
    } else {
#if PEPEPOW_CUDA_SCALED_NIBBLE_TABLE
        sum += __ldg(scaled_nibble_cell + nibble);
#elif PEPEPOW_CUDA_SCALED_MATRIX
        sum += *matrix_cell * value;
#else
        sum += *matrix_cell * 0.0001 * value;
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
    const double* matrix_cell = matrix + row_offset;
    const double* scaled_nibble_cell =
        scaled_nibble_table + static_cast<std::size_t>(row_offset) * 16U;
#if PEPEPOW_CUDA_BYTE_UNROLL == 4
    #pragma unroll 4
#elif PEPEPOW_CUDA_BYTE_UNROLL == 2
    #pragma unroll 2
#else
    #pragma unroll 1
#endif
    for (int word_index = 0; word_index < 8; ++word_index) {
        const std::uint32_t packed_word = first_pass[word_index];
        #pragma unroll
        for (int byte_in_word = 0; byte_in_word < 4; ++byte_in_word) {
            const std::uint8_t packed = static_cast<std::uint8_t>(
                packed_word >> static_cast<unsigned int>(byte_in_word * 8));
            const std::uint32_t high_nibble =
                static_cast<std::uint32_t>(packed >> 4U);
            const std::uint32_t low_nibble =
                static_cast<std::uint32_t>(packed & 0x0fU);
            accumulate_pointer(matrix_cell, scaled_nibble_cell,
                               high_nibble, nibble_to_double(high_nibble),
                               hash_mod_fp64, nonce_mod, sum, sw);
            ++matrix_cell;
            scaled_nibble_cell += 16;
            accumulate_pointer(matrix_cell, scaled_nibble_cell,
                               low_nibble, nibble_to_double(low_nibble),
                               hash_mod_fp64, nonce_mod, sum, sw);
            ++matrix_cell;
            scaled_nibble_cell += 16;
        }
    }
    return sum;
}

'''
    text = replace_between(
        text,
        "__device__ __forceinline__ void accumulate(",
        "__device__ __forceinline__ bool hash_words_meet_target",
        pointer_walk,
        "pointer walk",
    )
elif "unlikely" in mode:
    old = "    if (sw_state_is_cold(sw)) {"
    new = "    if (__builtin_expect(static_cast<int>(sw_state_is_cold(sw)), 0)) {"
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"ERROR: cold branch count={count}")
    text = text.replace(old, new, 1)

path.write_text(text, encoding="utf-8")
