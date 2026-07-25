#pragma once

#include "pepepow/crypto/hoohash_reference.hpp"

#include <cstdint>

namespace pepepow::crypto {

struct PowInput {
    Hash256 previous_header{};
    std::int64_t timestamp{};
    std::uint64_t nonce{};
};

[[nodiscard]] Hash256 calculate_pow(const PowInput& input);

} // namespace pepepow::crypto
