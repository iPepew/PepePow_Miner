#include <cuda_runtime.h>
#include <cstddef>
#include <cstdint>

namespace pepepow::cuda_q20_probe {

constexpr int kRows = 64;
constexpr int kCols = 64;
constexpr int kNibbles = 16;
constexpr int kFracBits = 20;
constexpr std::int64_t kScale = std::int64_t{1} << kFracBits;
constexpr std::int64_t kPeriod = kScale * 1024;
constexpr std::int64_t kColdThreshold = (kPeriod * 2) / 100;

// The warm linear table is job-specific and precomputed on the host.
// Q20 bounds each entry so signed int32 storage is sufficient for the
// representative production matrix; the row accumulator remains int64.
__device__ __forceinline__ std::int32_t table_get(
    const std::int32_t* __restrict__ table,
    int row,
    int col,
    std::uint8_t nibble) {
    return table[(row * kCols + col) * kNibbles + static_cast<int>(nibble)];
}

// Resource probe for the production-shaped fast generator. Cold cells are
// deliberately marked instead of approximated here: the eventual integrated
// candidate must route every fast hit through the unchanged strict validator
// before any pool submit.
__global__ void hoohash_q20_fast_generator_probe(
    const std::uint8_t* __restrict__ nibbles,
    const std::int32_t* __restrict__ warm_table_q20,
    const std::int64_t* __restrict__ cold_contrib_q20,
    std::uint64_t* __restrict__ product_floor,
    std::uint8_t* __restrict__ saw_cold,
    std::size_t count) {
    const std::size_t idx = static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (idx >= count) return;

    const std::uint8_t* v = nibbles + idx * kCols;
    std::uint64_t* out = product_floor + idx * kRows;
    const std::int64_t* cold = cold_contrib_q20 + idx * kRows * kCols;

    bool is_cold = true;
    std::uint8_t cold_seen = 0;

    #pragma unroll 1
    for (int row = 0; row < kRows; ++row) {
        std::int64_t qsum = 0;
        #pragma unroll 1
        for (int col = 0; col < kCols; ++col) {
            const std::uint8_t nibble = v[col];
            if (is_cold) {
                cold_seen = 1;
                qsum += cold[row * kCols + col];
            } else {
                qsum += static_cast<std::int64_t>(table_get(warm_table_q20, row, col, nibble));
            }
            const std::int64_t rem = qsum % kPeriod;
            is_cold = rem <= kColdThreshold;
        }
        out[row] = static_cast<std::uint64_t>(qsum / kScale);
    }
    saw_cold[idx] = cold_seen;
}

// Marker kernel used by CI to keep the submit barrier explicit in the cubin.
// This is not a validator implementation and cannot authorize promotion.
__global__ void strict_validation_barrier_probe(
    const std::uint32_t* __restrict__ fast_candidates,
    std::uint32_t* __restrict__ validator_queue,
    std::size_t count) {
    const std::size_t idx = static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (idx < count) validator_queue[idx] = fast_candidates[idx];
}

} // namespace pepepow::cuda_q20_probe
