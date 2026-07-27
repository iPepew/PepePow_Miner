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

std::uint32_t load_le32(const std::uint8_t* value) noexcept {
    return static_cast<std::uint32_t>(value[0]) |
           (static_cast<std::uint32_t>(value[1]) << 8U) |
           (static_cast<std::uint32_t>(value[2]) << 16U) |
           (static_cast<std::uint32_t>(value[3]) << 24U);
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
    // The live PEPEPOW pool derives the HooHash V110 matrix from BLAKE3 of
    // Header80 with the four nonce bytes cleared. It hashes the complete header
    // separately and decodes the header nonce as LE32 for the nonlinear mix.
    Header80 masked_header = header;
    std::fill(masked_header.begin() + 76, masked_header.end(), 0U);

    const Hash256 matrix_seed = blake3_hash(masked_header);
    const Hash256 header_hash = blake3_hash(header);
    const std::uint32_t mix_nonce = load_le32(header.data() + 76);
    const HoohashMatrix matrix = generate_hoohash_matrix(matrix_seed);
    const Hash256 mixed = hoohash_matrix_mix(matrix, header_hash, mix_nonce);
    return blake3_hash(mixed);
}

} // namespace pepepow::crypto
