#pragma once

#include "pepepow/core/types.hpp"

#include <array>
#include <cstdint>

namespace pepepow::mining {

using Target256 = std::array<std::uint8_t, 32>;

inline constexpr double kStratumDifficultyWireScale = 65536.0;

// PEPEPOW pools expose difficulty in wire units. The conventional difficulty
// used for target calculation is wire_difficulty / 65536.
// Examples observed on a live pool:
//   98.304 -> 0.00150000
//   32     -> 0.00048828125
// The PEPEPOW diff1 baseline is:
// 0000ffff00000000000000000000000000000000000000000000000000000000.
// Returned bytes are big-endian, matching the conventional target display.
[[nodiscard]] Target256 target_from_difficulty(double stratum_difficulty);

// Compares a conventional big-endian 256-bit hash against a big-endian target.
[[nodiscard]] bool hash_meets_target_be(const Hash256& hash, const Target256& target) noexcept;

} // namespace pepepow::mining
