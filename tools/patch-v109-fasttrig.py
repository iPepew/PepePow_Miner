from pathlib import Path

# Apply AFTER prepare-v109-volta-geometry.py and AFTER the exact build has
# completed. This creates the optional fasttrig build. The physical V100
# autotuner compares exact and fasttrig executables, and every geometry must
# pass CPU/GPU HooHash validation before it may be selected.

p4 = Path('native/src/cuda/v1/header80_backend_part04.inc')
t4 = p4.read_text(encoding='utf-8')
marker = 'struct ColdServiceScratch {\n'
if marker not in t4:
    raise SystemExit('prepared ColdServiceScratch marker missing')

helper = r'''
// v1.0.9 Volta fasttrig -----------------------------------------------------
// HooHash feeds double-precision trig with finite arguments below 2^57. CUDA
// switches double sin/cos to its expensive general Payne-Hanek slow path above
// 2^31. For this restricted domain we can determine the nearest pi/2 multiple
// using 128 fixed bits of 2/pi, form a high-accuracy remainder with four
// non-overlapping pi/2 chunks, then call CUDA sincos() on the small remainder.
// The fasttrig binary is NEVER trusted blindly: the startup autotuner verifies
// complete GPU HooHash results against the CPU reference for every geometry,
// and live share candidates are still CPU validated before submission.

__device__ __forceinline__ bool v109_u192_bit(
    unsigned long long high, unsigned long long middle,
    unsigned long long low, unsigned int index) {
    if (index >= 128U) return ((high >> (index - 128U)) & 1ULL) != 0ULL;
    if (index >= 64U) return ((middle >> (index - 64U)) & 1ULL) != 0ULL;
    return ((low >> index) & 1ULL) != 0ULL;
}

__device__ __forceinline__ bool v109_u192_any_below(
    unsigned long long high, unsigned long long middle,
    unsigned long long low, unsigned int index) {
    // Test bits [0,index). v1.0.9 calls this only with index in [123,148].
    if (index == 0U) return false;
    if (index < 64U) {
        const unsigned long long mask = (1ULL << index) - 1ULL;
        return (low & mask) != 0ULL;
    }
    if (index == 64U) return low != 0ULL;
    if (index < 128U) {
        const unsigned int bits = index - 64U;
        const unsigned long long mask = (1ULL << bits) - 1ULL;
        return low != 0ULL || (middle & mask) != 0ULL;
    }
    if (index == 128U) return low != 0ULL || middle != 0ULL;
    const unsigned int bits = index - 128U;
    const unsigned long long mask = (1ULL << bits) - 1ULL;
    return low != 0ULL || middle != 0ULL || (high & mask) != 0ULL;
}

__device__ __forceinline__ unsigned long long v109_nearest_pio2_multiple(
    double positive_value) {
    constexpr unsigned long long kTwoOverPiHi = 0xa2f9836e4e441529ULL;
    constexpr unsigned long long kTwoOverPiLo = 0xfc2757d1f534ddc0ULL;
    constexpr unsigned long long kMantissaMask = 0x000fffffffffffffULL;

    const unsigned long long bits = static_cast<unsigned long long>(
        __double_as_longlong(positive_value));
    const unsigned int biased_exponent =
        static_cast<unsigned int>((bits >> 52U) & 0x7ffULL);
    const int exponent = static_cast<int>(biased_exponent) - 1023;
    const unsigned long long mantissa =
        (1ULL << 52U) | (bits & kMantissaMask);

    const unsigned long long low = mantissa * kTwoOverPiLo;
    const unsigned long long carry = __umul64hi(mantissa, kTwoOverPiLo);
    const unsigned long long middle_base = mantissa * kTwoOverPiHi;
    unsigned long long middle = middle_base + carry;
    unsigned long long high = __umul64hi(mantissa, kTwoOverPiHi);
    if (middle < middle_base) ++high;

    // value = mantissa*2^(exponent-52), while the constant is scaled by 2^128.
    // Therefore q = round(product / 2^(180-exponent)). In the restricted HooHash
    // range exponent is [31,56], so shift is [124,149] and q fits in 57 bits.
    const unsigned int shift = static_cast<unsigned int>(180 - exponent);
    unsigned long long q;
    if (shift >= 128U) {
        const unsigned int amount = shift - 128U;
        q = amount == 0U ? high : (high >> amount);
    } else {
        const unsigned int amount = shift - 64U;
        q = (middle >> amount) | (high << (64U - amount));
    }

    const unsigned int half_index = shift - 1U;
    const bool half = v109_u192_bit(high, middle, low, half_index);
    const bool lower = v109_u192_any_below(high, middle, low, half_index);
    if (half && (lower || ((q & 1ULL) != 0ULL))) ++q;
    return q;
}

__device__ __forceinline__ void v109_dd_add(
    double value, double& high, double& low) {
    const double sum = high + value;
    const double bb = sum - high;
    const double error = (high - (sum - bb)) + (value - bb);
    const double tail = low + error;
    const double result = sum + tail;
    low = tail - (result - sum);
    high = result;
}

__device__ __forceinline__ void v109_fast_sincos(
    double value, double* sine_out, double* cosine_out) {
    constexpr double kCudaFastTrigLimit = 0x1p31;
    constexpr double kHooHashReducerLimit = 0x1p57;
    const double absolute = fabs(value);
    if (absolute < kCudaFastTrigLimit || absolute >= kHooHashReducerLimit ||
        !isfinite(value)) {
        sincos(value, sine_out, cosine_out);
        return;
    }

    const bool negative = value < 0.0;
    const unsigned long long q = v109_nearest_pio2_multiple(absolute);
    constexpr unsigned long long kChunkMask = (1ULL << 19U) - 1ULL;
    const double q0 = static_cast<double>(q & kChunkMask);
    const double q1 = static_cast<double>((q >> 19U) & kChunkMask) * 0x1p19;
    const double q2 = static_cast<double>(q >> 38U) * 0x1p38;

    // Four non-overlapping 27-bit chunks of pi/2. Their omitted tail is below
    // 2.1e-43; multiplied by the largest HooHash quadrant index it contributes
    // less than 2e-26 to the reduced angle.
    constexpr double p1 = 0x1.921fb54000000p+0;
    constexpr double p2 = 0x1.10b4610000000p-30;
    constexpr double p3 = 0x1.a626330000000p-58;
    constexpr double p4 = 0x1.45c06e0000000p-86;

    double remainder_high = absolute;
    double remainder_low = 0.0;
#define V109_SUB_PIO2_CHUNK(Q, P) \
    do { if ((Q) != 0.0) v109_dd_add(-((Q) * (P)), remainder_high, remainder_low); } while (0)
    V109_SUB_PIO2_CHUNK(q2, p1);
    V109_SUB_PIO2_CHUNK(q1, p1);
    V109_SUB_PIO2_CHUNK(q0, p1);
    V109_SUB_PIO2_CHUNK(q2, p2);
    V109_SUB_PIO2_CHUNK(q1, p2);
    V109_SUB_PIO2_CHUNK(q0, p2);
    V109_SUB_PIO2_CHUNK(q2, p3);
    V109_SUB_PIO2_CHUNK(q1, p3);
    V109_SUB_PIO2_CHUNK(q0, p3);
    V109_SUB_PIO2_CHUNK(q2, p4);
    V109_SUB_PIO2_CHUNK(q1, p4);
    V109_SUB_PIO2_CHUNK(q0, p4);
#undef V109_SUB_PIO2_CHUNK

    double remainder = remainder_high + remainder_low;
    unsigned int quadrant = static_cast<unsigned int>(q & 3ULL);
    if (negative) {
        remainder = -remainder;
        quadrant = (4U - quadrant) & 3U;
    }

    double reduced_sine, reduced_cosine;
    sincos(remainder, &reduced_sine, &reduced_cosine);
    if (quadrant == 0U) {
        *sine_out = reduced_sine;
        *cosine_out = reduced_cosine;
    } else if (quadrant == 1U) {
        *sine_out = reduced_cosine;
        *cosine_out = -reduced_sine;
    } else if (quadrant == 2U) {
        *sine_out = -reduced_sine;
        *cosine_out = -reduced_cosine;
    } else {
        *sine_out = -reduced_cosine;
        *cosine_out = reduced_sine;
    }
}
// ---------------------------------------------------------------------------

'''

t4 = t4.replace(marker, helper + marker, 1)
p4.write_text(t4, encoding='utf-8')

p5 = Path('native/src/cuda/v1/header80_backend_part05.inc')
t5 = p5.read_text(encoding='utf-8')
old_medium = '''            double sine, cosine;
            sincos(y, &sine, &cosine);
            nonlinear_value = exp(sine + cosine);'''
new_medium = '''            double sine, cosine;
            v109_fast_sincos(y, &sine, &cosine);
            nonlinear_value = exp(sine + cosine);'''
if old_medium not in t5:
    raise SystemExit('prepared service medium trig marker missing')
t5 = t5.replace(old_medium, new_medium, 1)
old_intermediate = '''            } else {
                const double sine = sin(y);
                nonlinear_value = sine * sine;
            }'''
new_intermediate = '''            } else {
                double sine, cosine_unused;
                v109_fast_sincos(y, &sine, &cosine_unused);
                nonlinear_value = sine * sine;
            }'''
if old_intermediate not in t5:
    raise SystemExit('prepared service intermediate trig marker missing')
t5 = t5.replace(old_intermediate, new_intermediate, 1)
p5.write_text(t5, encoding='utf-8')

verify4 = p4.read_text(encoding='utf-8')
verify5 = p5.read_text(encoding='utf-8')
assert 'kTwoOverPiHi = 0xa2f9836e4e441529ULL' in verify4
assert 'v109_nearest_pio2_multiple' in verify4
assert 'v109_fast_sincos' in verify4
assert '0x1.45c06e0000000p-86' in verify4
assert verify5.count('v109_fast_sincos') >= 2
assert 'sincos(y, &sine, &cosine);' not in verify5
print('V109_FASTTRIG_PATCH=PASS')
