#include <cuda_runtime.h>
#include <cmath>
#include <cstddef>

#ifndef PROBE_KIND
#define PROBE_KIND 0
#endif

namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr double kTransformMultiplier = 0.000001;

__device__ __forceinline__ double transform(double x) {
    const double two_base = x * kTransformMultiplier / 4.0;
    const double two = two_base - floor(two_base);
    if (two < 0.25) return x + (1.0 + two);
    if (two < 0.50) return x - (1.0 + two);
    if (two < 0.75) return x * (1.0 + two);
    return x / (1.0 + two);
}

__device__ __forceinline__ double probe(double x) {
    const double y = transform(x);
#if PROBE_KIND == 0
    double s, c;
    sincos(y, &s, &c);
    return exp(s + c);
#elif PROBE_KIND == 1
    if (y == kPi / 2.0 || y == 3.0 * kPi / 2.0) return 0.0;
    const double s = sin(y);
    return s * s;
#elif PROBE_KIND == 2
    return 1.0 / sqrt(fabs(y) + 1.0);
#else
#error Unsupported PROBE_KIND
#endif
}
}

extern "C" __global__ void nonlinear_sass_probe(const double* input, double* output, std::size_t count) {
    const std::size_t i = static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (i >= count) return;
    const double x = input[i];
    output[i] = probe(x);
}
