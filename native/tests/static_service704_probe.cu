#include <cuda_runtime.h>
#include <cmath>
#include <cstdint>

namespace {

constexpr unsigned int kThreads = 704U;
constexpr unsigned int kServiceThreads = 128U;
constexpr unsigned int kOwnerThreads = kThreads - kServiceThreads; // 576 = 18 warps
constexpr unsigned int kOwnerWarps = kOwnerThreads / 32U;
constexpr unsigned int kServiceWarps = kServiceThreads / 32U;

struct StaticServiceScratch {
    double task_x[kOwnerThreads];
    double task_value[kOwnerThreads];
    double task_result[kOwnerThreads];
    unsigned int task[kOwnerThreads];
};

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

// Preserve the verified 704-thread geometry and the full 128-thread nonlinear
// service width, but remove dynamic atomicAdd/task_owner compaction. Every owner
// thread owns a deterministic scratch slot. Four service warps consume those
// slots by static warp partitioning. This probe deliberately keeps the two
// block-wide phase barriers so the first experiment isolates queue/compaction
// overhead from synchronization topology.
__global__ __launch_bounds__(704, 1)
void static_service704_probe(const double* __restrict__ input,
                             const std::uint32_t* __restrict__ selector,
                             double* __restrict__ output,
                             std::size_t owner_count) {
    __shared__ StaticServiceScratch scratch;

    const unsigned int tid = static_cast<unsigned int>(threadIdx.x);
    const bool service = tid < kServiceThreads;
    const unsigned int owner_tid = tid - kServiceThreads;
    const bool owner = !service;
    const std::size_t owner_index = static_cast<std::size_t>(blockIdx.x) * kOwnerThreads + owner_tid;
    const bool active = owner && owner_index < owner_count;

    double acc = 0.0;
    double x = active ? input[owner_index] : 0.0;
    std::uint32_t sel = active ? selector[owner_index] : 0U;

    #pragma unroll 1
    for (int cell = 0; cell < 64; ++cell) {
        if (owner) {
            const bool task = active && (((sel + static_cast<unsigned int>(cell)) & 7U) != 0U);
            scratch.task[owner_tid] = task ? 1U : 0U;
            scratch.task_x[owner_tid] = x + static_cast<double>(cell) * 0.0001;
            scratch.task_value[owner_tid] = 1.0 + static_cast<double>((sel >> 4U) & 15U);
        }

        __syncthreads();

        if (service) {
            const unsigned int service_warp = tid >> 5U;
            const unsigned int lane = tid & 31U;
            // 18 owner warps split deterministically as 5/5/4/4 across service warps.
            const unsigned int first_warp = service_warp < 2U ? service_warp * 5U : 10U + (service_warp - 2U) * 4U;
            const unsigned int warp_count = service_warp < 2U ? 5U : 4U;
            #pragma unroll 1
            for (unsigned int w = 0; w < warp_count; ++w) {
                const unsigned int slot = (first_warp + w) * 32U + lane;
                if (scratch.task[slot]) {
                    const double r = exact_nonlinear(scratch.task_x[slot], sel + static_cast<unsigned int>(cell));
                    scratch.task_result[slot] = r * scratch.task_value[slot];
                }
            }
        }

        __syncthreads();

        if (active) {
            if (scratch.task[owner_tid]) acc += scratch.task_result[owner_tid];
            else acc += scratch.task_x[owner_tid] * 0.0001;
            x = acc * 0.999999 + x * 0.000001;
            sel = sel * 1664525U + 1013904223U;
        }
    }

    if (active) output[owner_index] = acc;
}

} // namespace
