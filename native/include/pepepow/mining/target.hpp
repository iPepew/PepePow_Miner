#pragma once

#include "pepepow/core/types.hpp"

#include <array>
#include <cstdint>

namespace pepepow::mining {

using Target256 = std::array<std::uint8_t, 32>;

inline constexpr double kStratumDifficultyWireScale = 65536.0;

// PEPEPOW Stratum sends difficulty in wire units. One displayed Stratum unit
// corresponds to 65536 conventional diff1 units for target calculation.
// The PEPEPOW diff1 baseline is:
// 0000ffff00000000000000000000000000000000000000000000000000000000.
// Returned bytes are big-endian, matching the conventional target display.
[[nodiscard]] Target256 target_from_difficulty(double stratum_difficulty);

// Compares a conventional big-endian 256-bit hash against a big-endian target.
[[nodiscard]] bool hash_meets_target_be(const Hash256& hash, const Target256& target) noexcept;

} // namespace pepepow::mining
