#include <cuda_runtime.h>
#include <cstddef>
#include <cstdint>

namespace pepepow::cuda_q20_probe {

constexpr int kRows = 64;
constexpr int kCols = 64;
constexpr int kNibbles = 16;
constexpr int kFracBits = 20;
constexpr std::uint64_t kScale = std::uint64_t{1} << kFracBits;
constexpr std::uint64_t kPeriod = kScale * 1024ULL; // 2^30 for Q20
constexpr std::uint64_t kPeriodMask = kPeriod - 1ULL;
constexpr std::uint64_t kColdThreshold = (kPeriod * 2ULL) / 100ULL;
static_assert((kPeriod & (kPeriod - 1ULL)) == 0ULL, "Q20 period must be power-of-two");

// Profiling-driven Q20 successor for Volta: preserve the same fixed-point
// approximation, but remove 64-bit remainder/divide from the 64-column hot loop.
// Q20 contributions are non-negative for the verified fixed job/path, so the
// modulo by 2^30 is exactly equivalent to a mask and division by 2^20 to shift.
__device__ __forceinline__ std::int32_t table_get(
    const std::int32_t* __restrict__ table,
    int row,
    int col,
    std::uint8_t nibble) {
    return table[(row * kCols + col) * kNibbles + static_cast<int>(nibble)];
}

__global__ void hoohash_q20_bitmask_fast_generator_probe(
    const std::uint8_t* __restrict__ nibbles,
    const std::int32_t* __restrict__ warm_table_q20,
    const std::uint64_t* __restrict__ cold_contrib_q20,
    std::uint64_t* __restrict__ product_floor,
    std::uint8_t* __restrict__ saw_cold,
    std::size_t count) {
    const std::size_t idx = static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (idx >= count) return;

    const std::uint8_t* v = nibbles + idx * kCols;
    std::uint64_t* out = product_floor + idx * kRows;
    const std::uint64_t* cold = cold_contrib_q20 + idx * kRows * kCols;

    bool is_cold = true;
    std::uint8_t cold_seen = 0;

    #pragma unroll 1
    for (int row = 0; row < kRows; ++row) {
        std::uint64_t qsum = 0;
        #pragma unroll 1
        for (int col = 0; col < kCols; ++col) {
            const std::uint8_t nibble = v[col];
            if (is_cold) {
                cold_seen = 1;
                qsum += cold[row * kCols + col];
            } else {
                qsum += static_cast<std::uint64_t>(table_get(warm_table_q20, row, col, nibble));
            }
            const std::uint64_t rem = qsum & kPeriodMask;
            is_cold = rem <= kColdThreshold;
        }
        out[row] = qsum >> kFracBits;
    }
    saw_cold[idx] = cold_seen;
}

__global__ void strict_validation_barrier_probe(
    const std::uint32_t* __restrict__ fast_candidates,
    std::uint32_t* __restrict__ validator_queue,
    std::size_t count) {
    const std::size_t idx = static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (idx < count) validator_queue[idx] = fast_candidates[idx];
}

} // namespace pepepow::cuda_q20_probe
