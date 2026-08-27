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

// Host-only census used by the speculative/filter research branch. It observes
// the exact consensus reference without changing normal HooHash behaviour.
struct HooHashNonlinearCensus {
    std::uint64_t nonces{};
    std::uint64_t matrix_cells{};
    std::uint64_t nonlinear_cells{};
    std::uint64_t linear_cells{};
    std::uint64_t zero_nibble_skips{};
    std::array<std::uint64_t, 3> nonlinear_branch_counts{}; // exp(sin+cos), sin^2, invsqrt
    std::array<std::uint64_t, 4> transform_counts{};        // add, sub, mul, div
    std::uint64_t retry_rounds{};
    double x_min{};
    double x_max{};
    std::array<double, 3> y_min{};
    std::array<double, 3> y_max{};
};

[[nodiscard]] Xoshiro256pp make_xoshiro(const Hash256& seed) noexcept;
[[nodiscard]] HoohashMatrix generate_hoohash_matrix(const Hash256& seed);

// Produces the 32-byte buffer that HooHash V110 passes through its final BLAKE3.
[[nodiscard]] Hash256 hoohash_matrix_mix(
    const HoohashMatrix& matrix,
    const Hash256& first_pass,
    std::uint64_t nonce);

// Exact-reference equivalent of hoohash_matrix_mix that additionally updates
// branch/range statistics. Intended only for fixed-job profiling in CI/lab.
[[nodiscard]] Hash256 hoohash_matrix_mix_profiled(
    const HoohashMatrix& matrix,
    const Hash256& first_pass,
    std::uint64_t nonce,
    HooHashNonlinearCensus& census);

} // namespace pepepow::crypto
