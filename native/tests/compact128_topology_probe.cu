#include <cuda_runtime.h>
#include <cstdint>

namespace {

struct CompactBlockState {
    double lane_accum[128];
    double row_partial[128];
    std::uint32_t sw[128];
    std::uint32_t flags[128];
    std::uint32_t queue[128];
    std::uint32_t queue_count;
};

__device__ __forceinline__ double mix_fp64(double x, double m, std::uint32_t nibble) {
    double y = x + m * (static_cast<double>(nibble) * 0.0001);
    y = fma(y, 1.00000011920928955078125, m);
    y = y / (fabs(y) + 1.0);
    return y;
}

__global__ __launch_bounds__(128) void compact128_topology_probe(
    const double* __restrict__ matrix,
    const std::uint32_t* __restrict__ words,
    double* __restrict__ sink,
    std::uint32_t nonce_base) {
    __shared__ CompactBlockState s;

    const unsigned lane = threadIdx.x;
    const unsigned nonce = nonce_base + blockIdx.x;
    const std::uint32_t w = words[(nonce + lane) & 255U];
    const std::uint32_t nibble = (w >> ((lane & 7U) * 4U)) & 0xFU;

    double acc = static_cast<double>(nonce ^ (lane * 0x9e3779b9U)) * 0x1p-32;
    std::uint32_t sw = w ^ nonce;

    #pragma unroll 4
    for (unsigned row = 0; row < 64; ++row) {
        const unsigned cell = ((row * 64U) + (lane & 63U)) & 4095U;
        const double m = __ldg(matrix + cell);
        const double v = mix_fp64(acc, m, nibble);
        s.lane_accum[lane] = v;
        s.row_partial[lane] = v * ((lane & 1U) ? -1.0 : 1.0);
        s.sw[lane] = sw;
        s.flags[lane] = static_cast<std::uint32_t>(fabs(v) > 0.5);
        __syncthreads();

        if (lane < 64U) {
            const double pair = s.row_partial[lane] + s.row_partial[lane + 64U];
            s.row_partial[lane] = pair;
        }
        __syncthreads();

        if (lane < 32U) s.row_partial[lane] += s.row_partial[lane + 32U];
        __syncthreads();
        if (lane < 16U) s.row_partial[lane] += s.row_partial[lane + 16U];
        __syncthreads();
        if (lane < 8U) s.row_partial[lane] += s.row_partial[lane + 8U];
        __syncthreads();
        if (lane < 4U) s.row_partial[lane] += s.row_partial[lane + 4U];
        __syncthreads();
        if (lane < 2U) s.row_partial[lane] += s.row_partial[lane + 2U];
        __syncthreads();
        if (lane == 0U) s.row_partial[0] += s.row_partial[1];
        __syncthreads();

        const double row_sum = s.row_partial[0];
        acc = fma(acc, 0.999999940395355224609375, row_sum * 0x1p-12);
        sw ^= __double2loint(row_sum) + row * 0x85ebca6bU;
    }

    if (lane == 0U) {
        sink[blockIdx.x] = acc + static_cast<double>(sw & 0xffffU);
    }
}

} // namespace
