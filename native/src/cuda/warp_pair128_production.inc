// Production 128-thread nonce-local topology for Volta.
// Legacy selector/name is retained only to keep the existing A/B packaging path
// isolated. Every thread owns one nonce end-to-end: no dedicated service warps,
// block-wide task queue, task atomics, shared scratch or inter-thread barriers.
// Exact consensus nonlinear math remains in the owning lane via hoohash_mix_words().

__global__ __launch_bounds__(128, 1)
void header80_pow_warp_pair128_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    DeviceShareResult* __restrict__ result,
    std::size_t count) {
    const std::size_t index =
        static_cast<std::size_t>(blockIdx.x) * 128U +
        static_cast<unsigned int>(threadIdx.x);
    if (index >= count) return;

    const std::uint32_t nonce =
        first_nonce + static_cast<std::uint32_t>(index);
    std::uint32_t first_pass[8]{};
    std::uint32_t mixed[8]{};
    std::uint32_t final_hash[8]{};

    blake3_header80_words(nonce, first_pass);
    hoohash_mix_words(
        matrix, scaled_nibble_table, byte_swap32(nonce), first_pass, mixed);
    blake3_32_words(mixed, final_hash);

    if (!hash_words_meet_target(final_hash)) return;
    if (atomicCAS(&result->found, 0U, 1U) == 0U) {
        result->nonce = nonce;
        #pragma unroll
        for (int i = 0; i < 8; ++i) result->hash_words[i] = final_hash[i];
    }
}
