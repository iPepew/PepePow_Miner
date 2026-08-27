#include <cuda_runtime.h>
#include <cstdint>

namespace {
constexpr unsigned kThreads = 704;
constexpr unsigned kGroups = 4;

struct GroupQueue {
    unsigned count[kGroups];
    double x[kGroups][192];
    double value[kGroups][192];
    double result[kThreads];
    unsigned owner[kGroups][192];
};

__device__ __forceinline__ double nonlinear_probe(double x) {
    const double ax = fabs(x);
    if (ax < 1.0) return exp(sin(x) + cos(x));
    if (ax < 2.0) { const double s = sin(x); return s * s; }
    if (ax < 3.0) return cos(x) * cos(x);
    return 1.0 / sqrt(ax + 1.0);
}

__device__ __forceinline__ unsigned group_for_warp(unsigned warp) {
    return warp < 6 ? 0U : (warp < 12 ? 1U : (warp < 17 ? 2U : 3U));
}

__device__ __forceinline__ unsigned group_first_warp(unsigned group) {
    return group == 0U ? 0U : (group == 1U ? 6U : (group == 2U ? 12U : 17U));
}

__device__ __forceinline__ unsigned group_thread_count(unsigned group) {
    return group < 2U ? 192U : 160U;
}

__device__ __forceinline__ unsigned group_capacity(unsigned group) {
    return group < 2U ? 192U : 160U;
}

__device__ __forceinline__ void group_barrier(unsigned group) {
    const unsigned count = group_thread_count(group);
    asm volatile("bar.sync %0, %1;" :: "r"(group + 1U), "r"(count) : "memory");
}

__global__ __launch_bounds__(kThreads, 1)
void hierarchical_service704_probe(const double* __restrict__ in,
                                   double* __restrict__ out,
                                   unsigned n) {
    __shared__ GroupQueue q;
    const unsigned tid = threadIdx.x;
    const unsigned warp = tid >> 5;
    const unsigned lane = tid & 31U;
    const unsigned group = group_for_warp(warp);
    const unsigned first_warp = group_first_warp(group);
    const unsigned local_tid = (warp - first_warp) * 32U + lane;
    const bool active = tid < n;

    if (local_tid == 0U) q.count[group] = 0U;
    group_barrier(group);

    double acc = active ? in[tid] : 0.0;
    #pragma unroll 1
    for (int step = 0; step < 8; ++step) {
        const bool task = active && (((static_cast<unsigned>(step) + tid) & 3U) == 0U);
        const unsigned mask = __ballot_sync(0xffffffffU, task);
        unsigned slot = 0U;
        if (mask) {
            const int leader = __ffs(static_cast<int>(mask)) - 1;
            unsigned base = 0U;
            if (static_cast<int>(lane) == leader) base = atomicAdd(&q.count[group], __popc(mask));
            base = __shfl_sync(0xffffffffU, base, leader);
            const unsigned lower = lane == 0U ? 0U : ((1U << lane) - 1U);
            slot = base + __popc(mask & lower);
            if (task && slot < group_capacity(group)) {
                q.x[group][slot] = acc + static_cast<double>(step) * 0.125;
                q.value[group][slot] = 1.0 + static_cast<double>(lane) * 0.01;
                q.owner[group][slot] = tid;
            }
        }

        group_barrier(group);

        const bool service_warp = warp == first_warp;
        if (service_warp) {
            const unsigned count = q.count[group];
            for (unsigned i = lane; i < count; i += 32U) {
                const unsigned owner = q.owner[group][i];
                q.result[owner] = nonlinear_probe(q.x[group][i]) * q.value[group][i];
            }
            if (lane == 0U) q.count[group] = 0U;
        }

        group_barrier(group);
        if (task) acc += q.result[tid];
    }
    if (active) out[tid] = acc;
}
} // namespace
