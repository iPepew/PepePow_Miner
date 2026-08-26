#pragma once

#include <cuda_runtime.h>
#include <cmath>
#include <cstdint>

namespace pepepow::cuda_guarded_lut {

constexpr unsigned kExpLutIntervals = 98304U;   // ~768 KiB FP64
constexpr unsigned kSin2LutIntervals = 16384U;  // ~128 KiB FP64
constexpr double kTwoPi = 6.2831853071795864769252867665590057683943387987502;

// Strict interpolation error bounds established by the host proofs.
constexpr double kExpInterpAbsError = 7.1713876655798894e-09;
constexpr double kSin2InterpAbsError = 3.6767141525035195e-08;

__device__ __forceinline__ void mul53x192(
    unsigned long long m,
    unsigned long long& p0,
    unsigned long long& p1,
    unsigned long long& p2,
    unsigned long long& p3) {
    // floor(2^192 / (2*pi)) =
    // 0x28be60db9391054a7f09d5f47d4d377036d8a5664f10e410
    constexpr unsigned long long c0 = 0x36d8a5664f10e410ULL;
    constexpr unsigned long long c1 = 0x7f09d5f47d4d3770ULL;
    constexpr unsigned long long c2 = 0x28be60db9391054aULL;

    const unsigned long long l0 = m * c0;
    const unsigned long long h0 = __umul64hi(m, c0);
    const unsigned long long l1 = m * c1;
    const unsigned long long h1 = __umul64hi(m, c1);
    const unsigned long long l2 = m * c2;
    const unsigned long long h2 = __umul64hi(m, c2);

    p0 = l0;
    p1 = h0 + l1;
    const unsigned long long carry1 = (p1 < h0) ? 1ULL : 0ULL;
    const unsigned long long t = h1 + l2;
    const unsigned long long carry2a = (t < h1) ? 1ULL : 0ULL;
    p2 = t + carry1;
    const unsigned long long carry2b = (p2 < t) ? 1ULL : 0ULL;
    p3 = h2 + carry2a + carry2b;
}

// Returns the fractional phase y/(2*pi) in unsigned Q0.64 form.
// False means the caller must execute the exact transcendental fallback.
__device__ __forceinline__ bool phase_frac64(double y, unsigned long long& frac) {
    const unsigned long long bits =
        static_cast<unsigned long long>(__double_as_longlong(fabs(y)));
    const unsigned eb = static_cast<unsigned>((bits >> 52) & 0x7ffULL);
    if (eb == 0U || eb == 0x7ffU) return false;

    const int exponent = static_cast<int>(eb) - 1023;
    const int shift_to_point = 244 - exponent;
    if (shift_to_point < 64 || shift_to_point > 256) return false;

    const unsigned long long mantissa =
        (bits & 0x000fffffffffffffULL) | 0x0010000000000000ULL;
    unsigned long long p0, p1, p2, p3;
    mul53x192(mantissa, p0, p1, p2, p3);

    const int bitpos = shift_to_point - 64;
    const int limb = bitpos >> 6;
    const int sh = bitpos & 63;
    unsigned long long lo = 0ULL;
    unsigned long long hi = 0ULL;
    if (limb == 0) { lo = p0; hi = p1; }
    else if (limb == 1) { lo = p1; hi = p2; }
    else if (limb == 2) { lo = p2; hi = p3; }
    else { lo = p3; hi = 0ULL; }

    frac = (sh == 0) ? lo : ((lo >> sh) | (hi << (64 - sh)));
    if (y < 0.0 && frac != 0ULL) frac = 0ULL - frac;
    return true;
}

template <unsigned Intervals>
__device__ __forceinline__ double lookup_linear(
    const double* __restrict__ lut,
    unsigned long long frac) {
    constexpr unsigned long long n = static_cast<unsigned long long>(Intervals);
    unsigned idx = static_cast<unsigned>(__umul64hi(frac, n));
    if (idx >= Intervals) idx = Intervals - 1U;
    const unsigned long long cell = frac * n;
    const double t = __ull2double_rn(cell) * 0x1p-64;
    const double a = __ldg(lut + idx);
    const double b = __ldg(lut + idx + 1U);
    return fma(b - a, t, a);
}

__device__ __forceinline__ bool exp_sincos_approx(
    double y,
    const double* __restrict__ lut,
    double& value,
    double& abs_error) {
    unsigned long long frac;
    if (!phase_frac64(y, frac)) return false;
    value = lookup_linear<kExpLutIntervals>(lut, frac);
    abs_error = kExpInterpAbsError;
    return true;
}

__device__ __forceinline__ bool sin2_approx(
    double y,
    const double* __restrict__ lut,
    double& value,
    double& abs_error) {
    unsigned long long frac;
    if (!phase_frac64(y, frac)) return false;
    value = lookup_linear<kSin2LutIntervals>(lut, frac);
    abs_error = kSin2InterpAbsError;
    return true;
}

} // namespace pepepow::cuda_guarded_lut
