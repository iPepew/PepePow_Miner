#pragma once

#include <cuda_runtime.h>
#include <cmath>
#include <cstdint>

namespace pepepow::cuda_guarded_sqrt {

constexpr double kInvSqrt2 =
    0.707106781186547524400844362104849039;

struct ApproxResult {
    double value;
    double abs_error;
    bool elided;
};

// Consensus-safe upper-bound primitive for the selector.one_region == 2 path.
// When elided=true, value is intentionally zero and abs_error bounds the
// omitted nonlinear contribution after applying contribution_scale. The caller
// must keep dependent HooHash state behind an interval guard and exact-replay
// the current row whenever the interval can alter SW or integer conversion.
__device__ __forceinline__ ApproxResult approximate_inverse_sqrt(
    double y, double contribution_scale) {
    const double a = fabs(y);
    const std::uint64_t bits =
        static_cast<std::uint64_t>(__double_as_longlong(a));
    const unsigned int exponent =
        static_cast<unsigned int>((bits >> 52U) & 0x7ffULL);

    // Small, subnormal and non-finite inputs stay exact. The exponent threshold
    // matches the proof/resource candidate and deliberately favors safety over
    // coverage for the first production integration.
    if (exponent == 0U || exponent == 0x7ffU || exponent < 1063U) {
        return {1.0 / sqrt(a + 1.0), 0.0, false};
    }

    const int k = static_cast<int>(exponent) - 1023;
    const int half = k >> 1;
    const unsigned int power_exp = static_cast<unsigned int>(1023 - half);
    double bound = __longlong_as_double(
        static_cast<long long>(static_cast<std::uint64_t>(power_exp) << 52U));
    if (k & 1) bound *= kInvSqrt2;

    return {0.0, bound * fabs(contribution_scale), true};
}

__device__ __forceinline__ bool same_positive_integer_interval(
    double sum, double radius) {
    if (!(radius >= 0.0) || !isfinite(sum) || !isfinite(radius)) return false;
    const double lo = fmax(0.0, sum - radius);
    const double hi = sum + radius;
    return static_cast<unsigned long long>(lo) ==
           static_cast<unsigned long long>(hi);
}

} // namespace pepepow::cuda_guarded_sqrt
