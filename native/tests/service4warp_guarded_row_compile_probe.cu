#include "../src/cuda/guarded_lut_primitives.cuh"

#include <cuda_runtime.h>
#include <cmath>
#include <cstdint>

namespace {

constexpr unsigned kThreads = 704U;
constexpr unsigned kServiceThreads = 128U;
constexpr double kTransformMultiplier = 0.000001;
constexpr double kPi = 3.14159265358979323846;

struct Scratch {
    unsigned task_count;
    double task_x[kThreads];
    double task_value[kThreads];
    double task_result[kThreads];
    double task_error[kThreads];
    unsigned task_owner[kThreads];
};

__device__ __forceinline__ double exact_nonlinear(double x) {
    const double one_base = x * kTransformMultiplier * 0.125;
    const double two_base = x * kTransformMultiplier * 0.25;
    const double one = one_base - floor(one_base);
    const double two = two_base - floor(two_base);
    double y;
    if (two < 0.25) y = x + (1.0 + two);
    else if (two < 0.50) y = x - (1.0 + two);
    else if (two < 0.75) y = x * (1.0 + two);
    else y = x / (1.0 + two);
    if (one < 0.33) {
        double s, c;
        sincos(y, &s, &c);
        return exp(s + c);
    }
    if (one < 0.66) {
        if (y == kPi / 2.0 || y == 3.0 * kPi / 2.0) return 0.0;
        const double s = sin(y);
        return s * s;
    }
    return 1.0 / sqrt(fabs(y) + 1.0);
}

__device__ __forceinline__ bool approx_nonlinear(
    double x,
    const double* exp_lut,
    const double* sin2_lut,
    double& value,
    double& error) {
    const double one_base = x * kTransformMultiplier * 0.125;
    const double two_base = x * kTransformMultiplier * 0.25;
    const double one = one_base - floor(one_base);
    const double two = two_base - floor(two_base);
    double y;
    if (two < 0.25) y = x + (1.0 + two);
    else if (two < 0.50) y = x - (1.0 + two);
    else if (two < 0.75) y = x * (1.0 + two);
    else y = x / (1.0 + two);

    if (one < 0.33) {
        return pepepow::cuda_guarded_lut::exp_sincos_approx(y, exp_lut, value, error);
    }
    if (one < 0.66) {
        if (y == kPi / 2.0 || y == 3.0 * kPi / 2.0) {
            value = 0.0;
            error = 0.0;
            return true;
        }
        return pepepow::cuda_guarded_lut::sin2_approx(y, sin2_lut, value, error);
    }
    value = 1.0 / sqrt(fabs(y) + 1.0);
    error = 0.0;
    return true;
}

__device__ __forceinline__ bool cold_from_sum(double sum) {
    const double q = sum * (1.0 / 1024.0);
    const double frac = q - floor(q);
    return frac <= 0.02;
}

__device__ __forceinline__ bool same_sw_interval(double sum, double radius) {
    const double lo = fmax(0.0, sum - radius);
    const double hi = sum + radius;
    return cold_from_sum(lo) == cold_from_sum(hi);
}

__device__ __forceinline__ bool same_integer_interval(double sum, double radius) {
    const double lo = fmax(0.0, sum - radius);
    const double hi = sum + radius;
    return __double2ull_rz(lo) == __double2ull_rz(hi);
}

__device__ __forceinline__ void run_service_cell(
    double x,
    double value,
    bool active,
    const double* exp_lut,
    const double* sin2_lut,
    Scratch& scratch,
    double& sum,
    double& radius,
    bool& ambiguous) {
    const unsigned lane = static_cast<unsigned>(threadIdx.x) & 31U;
    const unsigned mask = __activemask();
    const unsigned ballot = __ballot_sync(mask, active);
    unsigned slot = 0U;
    if (ballot != 0U) {
        const int leader = __ffs(static_cast<int>(ballot)) - 1;
        unsigned base = 0U;
        if (static_cast<int>(lane) == leader) {
            base = atomicAdd(&scratch.task_count, static_cast<unsigned>(__popc(ballot)));
        }
        base = __shfl_sync(mask, base, leader);
        const unsigned lower = lane == 0U ? 0U : ((1U << lane) - 1U);
        slot = base + static_cast<unsigned>(__popc(ballot & lower));
        if (active) {
            scratch.task_x[slot] = x;
            scratch.task_value[slot] = value;
            scratch.task_owner[slot] = static_cast<unsigned>(threadIdx.x);
        }
    }

    __syncthreads();
    const unsigned count = scratch.task_count;
    if (static_cast<unsigned>(threadIdx.x) < kServiceThreads) {
        for (unsigned i = static_cast<unsigned>(threadIdx.x); i < count; i += kServiceThreads) {
            double v = 0.0, e = 0.0;
            if (!approx_nonlinear(scratch.task_x[i], exp_lut, sin2_lut, v, e)) {
                v = exact_nonlinear(scratch.task_x[i]);
                e = 0.0;
            }
            const unsigned owner = scratch.task_owner[i];
            const double scale = scratch.task_value[i] * 1234.0;
            scratch.task_result[owner] = v * scale;
            scratch.task_error[owner] = e * fabs(scale);
        }
    }
    if (threadIdx.x == 0U) scratch.task_count = 0U;
    __syncthreads();

    if (active) {
        sum += scratch.task_result[threadIdx.x];
        radius += scratch.task_error[threadIdx.x];
        if (!same_sw_interval(sum, radius)) ambiguous = true;
    }
}

__device__ __noinline__ double exact_row_replay(double seed, double value) {
    double sum = 0.0;
    #pragma unroll 1
    for (int cell = 0; cell < 64; ++cell) {
        sum += exact_nonlinear(seed + static_cast<double>(cell)) * value * 1234.0;
    }
    return sum;
}

__global__ __launch_bounds__(704, 1)
void service4warp_guarded_row_probe(
    const double* exp_lut,
    const double* sin2_lut,
    const double* seed,
    double* output,
    unsigned count) {
    __shared__ Scratch scratch;
    if (threadIdx.x == 0U) scratch.task_count = 0U;
    __syncthreads();

    const unsigned index = blockIdx.x * blockDim.x + threadIdx.x;
    const bool active = index < count;
    const double base = active ? seed[index] : 0.0;
    const double value = static_cast<double>((index & 15U) + 1U);
    double sum = 0.0;
    double radius = 0.0;
    bool ambiguous = false;

    #pragma unroll 1
    for (int cell = 0; cell < 64; ++cell) {
        run_service_cell(base + static_cast<double>(cell), value, active,
                         exp_lut, sin2_lut, scratch, sum, radius, ambiguous);
    }

    if (active && (!same_integer_interval(sum, radius) || ambiguous)) {
        sum = exact_row_replay(base, value);
    }
    if (active) output[index] = sum;
}

} // namespace
