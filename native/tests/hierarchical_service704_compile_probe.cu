#include <cuda_runtime.h>
#include <cstdint>

namespace {
constexpr unsigned kThreads = 704;
constexpr unsigned kWarps = 22;
constexpr unsigned kServiceWarps = 4;
constexpr unsigned kGroups = 4;
constexpr unsigned kGroupWarpBegin[kGroups] = {0, 6, 12, 17};
constexpr unsigned kGroupWarpCount[kGroups] = {6, 6, 5, 5};
constexpr unsigned kGroupThreadCount[kGroups] = {192, 192, 160, 160};
constexpr unsigned kGroupCapacity[kGroups] = {192, 192, 160, 160};

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

__device__ __forceinline__ void group_barrier(unsigned group) {
    unsigned count = kGroupThreadCount[group];
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
    const unsigned group_first_warp = kGroupWarpBegin[group];
    const unsigned local_tid = (warp - group_first_warp) * 32U + lane;
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
            if (task && slot < kGroupCapacity[group]) {
                q.x[group][slot] = acc + static_cast<double>(step) * 0.125;
                q.value[group][slot] = 1.0 + static_cast<double>(lane) * 0.01;
                q.owner[group][slot] = tid;
            }
        }

        group_barrier(group);

        const bool service_warp = warp == group_first_warp;
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
