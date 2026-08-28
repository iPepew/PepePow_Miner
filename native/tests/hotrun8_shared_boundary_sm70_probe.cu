#include "../src/cuda/header80_backend.cu"

namespace pepepow {
namespace {

// Force the first BLAKE3 live range to terminate before HooHash begins.
// The 32-byte per-thread handoff stays on-chip in shared memory instead of
// making the global-memory round trip used by the proven two-stage fusion2.
__device__ __noinline__ void blake3_header80_to_shared(
    std::uint32_t nonce,
    std::uint32_t* __restrict__ shared_words) {
    std::uint32_t first_pass[8];
    blake3_header80_words(nonce, first_pass);
    #pragma unroll
    for (int i = 0; i < 8; ++i) shared_words[i] = first_pass[i];
}

__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void header80_hotrun8_shared_boundary_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    DeviceShareResult* __restrict__ result,
    std::size_t count) {
    __shared__ std::uint32_t first_pass_shared[PEPEPOW_CUDA_THREADS][8];

    const std::size_t index =
        static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) return;

    const std::uint32_t nonce = first_nonce + static_cast<std::uint32_t>(index);
    std::uint32_t* first_pass = first_pass_shared[threadIdx.x];
    blake3_header80_to_shared(nonce, first_pass);

    std::uint32_t mixed[8];
    std::uint32_t final_hash[8];
    hoohash_mix_words_hotrun8(
        matrix, scaled_nibble_table, byte_swap32(nonce), first_pass, mixed);
    blake3_32_words(mixed, final_hash);
    if (!hash_words_meet_target(final_hash)) return;
    if (atomicCAS(&result->found, 0U, 1U) == 0U) {
        result->nonce = nonce;
        #pragma unroll
        for (int i = 0; i < 8; ++i) result->hash_words[i] = final_hash[i];
    }
}

} // namespace
} // namespace pepepow
