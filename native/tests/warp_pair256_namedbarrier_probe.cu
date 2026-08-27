#include <cuda_runtime.h>
#include <cmath>
#include <cstdint>

namespace {

struct PairScratch {
    double task_x[32];
    double task_value[32];
    double task_result[32];
    unsigned int task[32];
};

__device__ __forceinline__ void pair_barrier(unsigned int id) {
    asm volatile("bar.sync %0, 64;" :: "r"(id) : "memory");
}

__device__ __forceinline__ double exact_nonlinear(double x, unsigned int selector) {
    const double two = static_cast<double>((selector >> 8U) & 0xffU) * (1.0 / 256.0);
    double y;
    if (two < 0.25) y = x + (1.0 + two);
    else if (two < 0.50) y = x - (1.0 + two);
    else if (two < 0.75) y = x * (1.0 + two);
    else y = x / (1.0 + two);

    switch (selector & 3U) {
        case 0U: return exp(sin(y) + cos(y));
        case 1U: { const double s = sin(y); return s * s; }
        case 2U: return 1.0 / sqrt(fabs(y) + 1.0);
        default: return y;
    }
}

// Four independent 64-thread owner/service pairs. This restores 128 nonlinear
// service threads (same service width as verified service4warp) while removing
// one global atomic task queue and block-wide synchronization from the probe.
// warp0<->1, warp2<->3, warp4<->5, warp6<->7.
__global__ __launch_bounds__(256, 1)
void warp_pair256_namedbarrier_probe(
    const double* __restrict__ input,
    const std::uint32_t* __restrict__ selector,
    double* __restrict__ output,
    std::size_t owner_count) {
    __shared__ PairScratch scratch[4];

    const unsigned int tid = static_cast<unsigned int>(threadIdx.x);
    const unsigned int warp = tid >> 5U;
    const unsigned int lane = tid & 31U;
    const unsigned int pair = warp >> 1U;
    const bool owner = (warp & 1U) == 0U;
    const unsigned int barrier_id = pair + 1U;

    const std::size_t owner_local = static_cast<std::size_t>(pair) * 32U + lane;
    const std::size_t owner_index = static_cast<std::size_t>(blockIdx.x) * 128U + owner_local;
    const bool active = owner && owner_index < owner_count;

    double acc = 0.0;
    double x = active ? input[owner_index] : 0.0;
    std::uint32_t sel = active ? selector[owner_index] : 0U;

    #pragma unroll 1
    for (int cell = 0; cell < 64; ++cell) {
        if (owner) {
            const bool cold_task = active && (((sel + static_cast<unsigned int>(cell)) & 7U) != 0U);
            scratch[pair].task[lane] = cold_task ? 1U : 0U;
            scratch[pair].task_x[lane] = x + static_cast<double>(cell) * 0.0001;
            scratch[pair].task_value[lane] = 1.0 + static_cast<double>((sel >> 4U) & 15U);
        }

        pair_barrier(barrier_id);

        if (!owner && scratch[pair].task[lane]) {
            const double r = exact_nonlinear(
                scratch[pair].task_x[lane], sel + static_cast<unsigned int>(cell));
            scratch[pair].task_result[lane] = r * scratch[pair].task_value[lane];
        }

        pair_barrier(barrier_id);

        if (owner && active) {
            if (scratch[pair].task[lane]) acc += scratch[pair].task_result[lane];
            else acc += scratch[pair].task_x[lane] * 0.0001;
            x = acc * 0.999999 + x * 0.000001;
            sel = sel * 1664525U + 1013904223U;
        }
    }

    if (active) output[owner_index] = acc;
}

} // namespace
