#pragma once

#include "pepepow/core/types.hpp"
#include "pepepow/crypto/hoohash_reference.hpp"

#include <cstdint>

namespace pepepow::crypto {

// Legacy development input retained for benchmark compatibility.
struct PowInput {
    Hash256 previous_header{};
    std::int64_t timestamp{};
    std::uint64_t nonce{};
};

[[nodiscard]] Hash256 calculate_pow(const PowInput& input);

// Canonical PEPEPOW V110 path used by Stratum and block validation.
// The 32-bit nonce is read from header bytes 76..79 in little-endian order.
// Matrix generation is seeded from the previous block hash at bytes 4..35.
[[nodiscard]] Hash256 calculate_header80_pow(const Header80& header);

} // namespace pepepow::crypto
