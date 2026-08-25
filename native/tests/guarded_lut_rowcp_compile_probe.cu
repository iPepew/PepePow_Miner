#include "../src/cuda/guarded_lut_primitives.cuh"

#include <cuda_runtime.h>
#include <cmath>
#include <cstdint>

using namespace pepepow::cuda_guarded_lut;

struct RowCheckpointProbeState {
    double sum;
    double error;
    double sw_center;
    unsigned int fallback;
};

__device__ __forceinline__ bool sw_interval_safe(double sum, double error) {
    const double lo = (sum - error) * (1.0 / 1024.0);
    const double hi = (sum + error) * (1.0 / 1024.0);
    const double flo = floor(lo);
    const double fhi = floor(hi);
    if (flo != fhi) return false;
    const double sw_lo = lo - flo;
    const double sw_hi = hi - fhi;
    return (sw_hi <= 0.02) || (sw_lo > 0.02);
}

__global__ void guarded_lut_rowcp_compile_probe(
    const double* __restrict__ matrix,
    const double* __restrict__ exp_lut,
    const double* __restrict__ sin2_lut,
    RowCheckpointProbeState* __restrict__ out,
    std::size_t count) {
    const std::size_t index = static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) return;

    const double hash_mod = 4294967291.0 - static_cast<double>(index & 1023U);
    const double nonce_mod = static_cast<double>(index & 255U);
    double sum = 0.0;
    double error = 0.0;
    bool fallback = false;

    #pragma unroll 1
    for (int cell = 0; cell < 64; ++cell) {
        const double value = static_cast<double>((cell + static_cast<int>(index)) & 15);
        if (value == 0.0) continue;
        const double x = __ldg(matrix + cell) * hash_mod * value + nonce_mod;
        const double one_base = x * 0.000001 * 0.125;
        const double one = one_base - floor(one_base);
        const double two_base = x * 0.000001 * 0.25;
        const double two = two_base - floor(two_base);
        double y;
        if (two < 0.25) y = x + (1.0 + two);
        else if (two < 0.50) y = x - (1.0 + two);
        else if (two < 0.75) y = x * (1.0 + two);
        else y = x / (1.0 + two);

        double nonlinear_value = 0.0;
        double nonlinear_error = 0.0;
        bool approximated = false;
        if (one < 0.33) {
            approximated = exp_sincos_approx(y, exp_lut, nonlinear_value, nonlinear_error);
        } else if (one < 0.66) {
            approximated = sin2_approx(y, sin2_lut, nonlinear_value, nonlinear_error);
        }

        if (!approximated) {
            fallback = true;
            break;
        }

        const double scale = value * 1234.0;
        sum = fma(nonlinear_value, scale, sum);
        error += nonlinear_error * fabs(scale);
        if (!sw_interval_safe(sum, error)) {
            fallback = true;
            break;
        }
    }

    RowCheckpointProbeState state{};
    state.sum = sum;
    state.error = error;
    const double sw_base = sum * (1.0 / 1024.0);
    state.sw_center = sw_base - floor(sw_base);
    state.fallback = fallback ? 1U : 0U;
    out[index] = state;
}
