#include <cuda_runtime.h>
#include <cmath>
#include <cstdint>

namespace {

constexpr unsigned int kThreads = 704U;
constexpr unsigned int kServiceThreads = 128U;

struct StaticServiceScratch {
    double task_x[kThreads];
    double task_value[kThreads];
    double task_result[kThreads];
    unsigned int task[kThreads];
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

// Match the verified service704 topology exactly: all 704 threads remain nonce
// owners, while threads 0..127 simultaneously act as nonlinear service workers.
// Every owner has one deterministic scratch slot, eliminating atomicAdd and
// task_owner compaction without reducing owner-side parallelism. The two
// block-wide barriers are deliberately preserved so this experiment isolates
// queue/compaction overhead only.
__global__ __launch_bounds__(704, 1)
void static_service704_probe(const double* __restrict__ input,
                             const std::uint32_t* __restrict__ selector,
                             double* __restrict__ output,
                             std::size_t owner_count) {
    __shared__ StaticServiceScratch scratch;

    const unsigned int tid = static_cast<unsigned int>(threadIdx.x);
    const std::size_t owner_index = static_cast<std::size_t>(blockIdx.x) * kThreads + tid;
    const bool active = owner_index < owner_count;

    double acc = 0.0;
    double x = active ? input[owner_index] : 0.0;
    std::uint32_t sel = active ? selector[owner_index] : 0U;

    #pragma unroll 1
    for (int cell = 0; cell < 64; ++cell) {
        const bool task = active && (((sel + static_cast<unsigned int>(cell)) & 7U) != 0U);
        scratch.task[tid] = task ? 1U : 0U;
        scratch.task_x[tid] = x + static_cast<double>(cell) * 0.0001;
        scratch.task_value[tid] = 1.0 + static_cast<double>((sel >> 4U) & 15U);

        __syncthreads();

        if (tid < kServiceThreads) {
            // Static striped ownership of all 704 slots across 128 workers.
            // No atomic counter and no task_owner indirection are required.
            for (unsigned int slot = tid; slot < kThreads; slot += kServiceThreads) {
                if (scratch.task[slot]) {
                    const double r = exact_nonlinear(
                        scratch.task_x[slot], selector[static_cast<std::size_t>(blockIdx.x) * kThreads + slot] +
                        static_cast<unsigned int>(cell));
                    scratch.task_result[slot] = r * scratch.task_value[slot];
                }
            }
        }

        __syncthreads();

        if (active) {
            if (task) acc += scratch.task_result[tid];
            else acc += scratch.task_x[tid] * 0.0001;
            x = acc * 0.999999 + x * 0.000001;
            sel = sel * 1664525U + 1013904223U;
        }
    }

    if (active) output[owner_index] = acc;
}

} // namespace
