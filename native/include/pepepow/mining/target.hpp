#pragma once

#include "pepepow/core/types.hpp"

#include <array>
#include <cstdint>

namespace pepepow::mining {

using Target256 = std::array<std::uint8_t, 32>;

// PEPEPOW Stratum uses its own diff1 baseline:
// 0000ffff00000000000000000000000000000000000000000000000000000000.
// Returned bytes are big-endian, matching the conventional target display.
[[nodiscard]] Target256 target_from_difficulty(double difficulty);

// Compares a conventional big-endian 256-bit hash against a big-endian target.
[[nodiscard]] bool hash_meets_target_be(const Hash256& hash, const Target256& target) noexcept;

} // namespace pepepow::mining
