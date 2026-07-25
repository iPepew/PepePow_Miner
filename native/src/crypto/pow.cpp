#include "pepepow/crypto/pow.hpp"

#include "pepepow/crypto/blake3.hpp"

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

} // namespace pepepow::crypto
