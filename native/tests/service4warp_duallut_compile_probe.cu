#include "../src/cuda/guarded_lut_primitives.cuh"

#include <cuda_runtime.h>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace {
constexpr unsigned kThreads = 704U;
constexpr unsigned kServiceThreads = 128U;

struct ServiceLutScratch {
    double y[kThreads];
    unsigned int region[kThreads];
    double result[kThreads];
    double abs_error[kThreads];
    unsigned int used_exact[kThreads];
};

__device__ __forceinline__ double exact_region(unsigned region, double y) {
    if (region == 0U) {
        double s, c;
        sincos(y, &s, &c);
        return exp(s + c);
    }
    if (region == 1U) {
        const double s = sin(y);
        return s * s;
    }
    return 1.0 / sqrt(fabs(y) + 1.0);
}

__device__ __forceinline__ void service_duallut_eval(
    unsigned region,
    double y,
    const double* __restrict__ exp_lut,
    const double* __restrict__ sin2_lut,
    double& result,
    double& abs_error,
    unsigned int& used_exact) {
    used_exact = 0U;
    abs_error = 0.0;

    bool ok = false;
    if (region == 0U) {
        ok = pepepow::cuda_guarded_lut::exp_sincos_approx(
            y, exp_lut, result, abs_error);
    } else if (region == 1U) {
        ok = pepepow::cuda_guarded_lut::sin2_approx(
            y, sin2_lut, result, abs_error);
    } else {
        result = exact_region(region, y);
        used_exact = 1U;
        return;
    }

    if (!ok) {
        result = exact_region(region, y);
        abs_error = 0.0;
        used_exact = 1U;
    }
}
} // namespace

extern "C" __global__ __launch_bounds__(704, 1)
void service4warp_duallut_compile_probe(
    const double* __restrict__ input_y,
    const unsigned int* __restrict__ input_region,
    const double* __restrict__ exp_lut,
    const double* __restrict__ sin2_lut,
    double* __restrict__ output,
    double* __restrict__ output_error,
    unsigned int* __restrict__ output_exact,
    std::size_t count) {
    __shared__ ServiceLutScratch scratch;

    const unsigned tid = static_cast<unsigned>(threadIdx.x);
    const std::size_t index = static_cast<std::size_t>(blockIdx.x) * blockDim.x + tid;
    const bool active = index < count;

    scratch.y[tid] = active ? input_y[index] : 0.0;
    scratch.region[tid] = active ? input_region[index] : 2U;
    __syncthreads();

    if (tid < kServiceThreads) {
        for (unsigned task = tid; task < kThreads; task += kServiceThreads) {
            double value = 0.0;
            double error = 0.0;
            unsigned int exact = 0U;
            service_duallut_eval(
                scratch.region[task], scratch.y[task], exp_lut, sin2_lut,
                value, error, exact);
            scratch.result[task] = value;
            scratch.abs_error[task] = error;
            scratch.used_exact[task] = exact;
        }
    }
    __syncthreads();

    if (active) {
        output[index] = scratch.result[tid];
        output_error[index] = scratch.abs_error[tid];
        output_exact[index] = scratch.used_exact[tid];
    }
}
