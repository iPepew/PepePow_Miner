// Production-shaped exact Header80/HooHash resource probe for the compact-128 topology.
// This deliberately reuses the validated v2.1 helpers byte-for-byte: the only
// experimental variable is launch topology (128 independent nonce threads per block,
// no 704-thread nonlinear service queue).
#include "../src/cuda/header80_backend.cu"

namespace pepepow {

__global__ __launch_bounds__(128) void compact128_header80_production_probe(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    std::uint32_t* __restrict__ sink,
    std::size_t count) {
    const std::size_t index =
        static_cast<std::size_t>(blockIdx.x) * 128U +
        static_cast<std::size_t>(threadIdx.x);
    if (index >= count) return;

    const std::uint32_t nonce =
        first_nonce + static_cast<std::uint32_t>(index);

    std::uint32_t first_pass[8];
    std::uint32_t mixed[8];
    std::uint32_t final_hash[8];

    blake3_header80_words(nonce, first_pass);
    hoohash_mix_words(
        matrix, scaled_nibble_table, byte_swap32(nonce), first_pass, mixed);
    blake3_32_words(mixed, final_hash);

    // Keep the production target predicate in the compiled hot path. The sink
    // prevents dead-code elimination without changing HooHash arithmetic.
    if (hash_words_meet_target(final_hash)) {
        sink[index] = final_hash[0] ^ final_hash[7] ^ nonce;
    }
}

} // namespace pepepow
