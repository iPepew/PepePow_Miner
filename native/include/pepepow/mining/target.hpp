#pragma once

#include "pepepow/core/types.hpp"

#include <array>
#include <cstdint>

namespace pepepow::mining {

using Target256 = std::array<std::uint8_t, 32>;

inline constexpr double kStratumDifficultyWireScale = 65536.0;

// Fixed diff1 pool policy, verified against RTX pool replies on 2026-10-19.
// Independent of network nBits; legacy network-relative policy remains below.
[[nodiscard]] Target256 target_from_fixed_difficulty(double stratum_difficulty);

// Decodes the compact nBits field into a conventional big-endian 256-bit
// network target. Negative, zero and overflowing compact values are rejected.
[[nodiscard]] Target256 target_from_compact(std::uint32_t compact_bits);

// PEPEPOW pool difficulty is relative to the network target carried by the
// current job, not to Bitcoin's fixed diff1 target. The miner-facing value is
// still transmitted in wire units, so:
//
//   share_target = network_target(nBits) / (wire_difficulty / 65536)
//
// The result is rounded conservatively down so the miner never submits a hash
// that is slightly above the pool's real boundary because of decimal precision.
[[nodiscard]] Target256 target_from_difficulty(
    double stratum_difficulty,
    std::uint32_t compact_bits);

// Compares a conventional big-endian 256-bit hash against a big-endian target.
[[nodiscard]] bool hash_meets_target_be(const Hash256& hash, const Target256& target) noexcept;

} // namespace pepepow::mining

