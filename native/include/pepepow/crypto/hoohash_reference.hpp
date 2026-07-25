#pragma once

#include <array>
#include <cstddef>
#include <cstdint>

namespace pepepow::crypto {

inline constexpr std::size_t kHashSize = 32;
inline constexpr std::size_t kMatrixSize = 64;

using Hash256 = std::array<std::uint8_t, kHashSize>;
using HoohashMatrix = std::array<std::array<double, kMatrixSize>, kMatrixSize>;

struct Xoshiro256pp {
    std::uint64_t s0{};
    std::uint64_t s1{};
    std::uint64_t s2{};
    std::uint64_t s3{};

    [[nodiscard]] std::uint64_t next() noexcept;
};

[[nodiscard]] Xoshiro256pp make_xoshiro(const Hash256& seed) noexcept;
[[nodiscard]] HoohashMatrix generate_hoohash_matrix(const Hash256& seed);

// Produces the 32-byte buffer that HooHash V110 passes through its final BLAKE3.
[[nodiscard]] Hash256 hoohash_matrix_mix(
    const HoohashMatrix& matrix,
    const Hash256& first_pass,
    std::uint64_t nonce);

} // namespace pepepow::crypto
