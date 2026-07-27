#include "pepepow/crypto/pow.hpp"

#include "pepepow/crypto/blake3.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>

namespace pepepow::crypto {
namespace {

void store_le64(std::uint8_t* out, std::uint64_t value) noexcept {
    for (std::size_t i = 0; i < 8; ++i) {
        out[i] = static_cast<std::uint8_t>((value >> (i * 8U)) & 0xffU);
    }
}

std::uint32_t load_be32(const std::uint8_t* value) noexcept {
    return (static_cast<std::uint32_t>(value[0]) << 24U) |
           (static_cast<std::uint32_t>(value[1]) << 16U) |
           (static_cast<std::uint32_t>(value[2]) << 8U) |
           static_cast<std::uint32_t>(value[3]);
}

} // namespace

Hash256 calculate_pow(const PowInput& input) {
    std::array<std::uint8_t, 80> first_pass_input{};
    for (std::size_t i = 0; i < input.previous_header.size(); ++i) {
        first_pass_input[i] = input.previous_header[i];
    }
    store_le64(first_pass_input.data() + 32, static_cast<std::uint64_t>(input.timestamp));
    store_le64(first_pass_input.data() + 72, input.nonce);

    const Hash256 first_pass = blake3_hash(first_pass_input);
    const HoohashMatrix matrix = generate_hoohash_matrix(input.previous_header);
    const Hash256 mixed = hoohash_matrix_mix(matrix, first_pass, input.nonce);
    return blake3_hash(mixed);
}

Hash256 calculate_header80_pow(const Header80& header) {
    Hash256 matrix_seed{};
    std::copy_n(header.begin() + 4, matrix_seed.size(), matrix_seed.begin());

    // HooHash V110 stores the nonce as BE32 in Header80. Decode the same
    // numeric nonce used by the CUDA kernel and by the matrix-mix stage.
    const std::uint32_t nonce = load_be32(header.data() + 76);
    const Hash256 first_pass = blake3_hash(header);
    const HoohashMatrix matrix = generate_hoohash_matrix(matrix_seed);
    const Hash256 mixed = hoohash_matrix_mix(matrix, first_pass, nonce);
    return blake3_hash(mixed);
}

} // namespace pepepow::crypto
