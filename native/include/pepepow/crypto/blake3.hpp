#pragma once

#include "pepepow/crypto/hoohash_reference.hpp"

#include <cstddef>
#include <cstdint>
#include <span>

namespace pepepow::crypto {

[[nodiscard]] Hash256 blake3_hash(std::span<const std::uint8_t> input);

} // namespace pepepow::crypto
