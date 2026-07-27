#include "pepepow/crypto/hoohash_reference.hpp"

#include <bit>
#include <cmath>
#include <cstdint>

namespace pepepow::crypto {
namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr double kTransformMultiplier = 0.000001;

[[nodiscard]] std::uint64_t load_le64(const std::uint8_t* p) noexcept {
    std::uint64_t value{};
    for (std::size_t i = 0; i < 8; ++i) {
        value |= static_cast<std::uint64_t>(p[i]) << (i * 8U);
    }
    return value;
}

[[nodiscard]] double medium(double x) { return std::exp(std::sin(x) + std::cos(x)); }
[[nodiscard]] double intermediate(double x) {
    if (x == kPi / 2.0 || x == 3.0 * kPi / 2.0) return 0.0;
    const double s = std::sin(x);
    return s * s;
}
[[nodiscard]] double high(double x) { return 1.0 / std::sqrt(std::fabs(x) + 1.0); }

[[nodiscard]] double complex_nonlinear(double x) {
    const double one = x * kTransformMultiplier / 8.0 - std::floor(x * kTransformMultiplier / 8.0);
    const double two = x * kTransformMultiplier / 4.0 - std::floor(x * kTransformMultiplier / 4.0);
    const auto apply = [x, two](auto fn) {
        if (two < 0.25) return fn(x + 1.0 + two);
        if (two < 0.50) return fn(x - 1.0 - two);
        if (two < 0.75) return fn(x * (1.0 + two));
        return fn(x / (1.0 + two));
    };
    if (one < 0.33) return apply(medium);
    if (one < 0.66) return apply(intermediate);
    return apply(high);
}

[[nodiscard]] double for_complex(double x) {
    double rounds = 1.0;
    double out = complex_nonlinear(x);
    while (std::isnan(out) || std::isinf(out)) {
        x *= 0.1;
        if (x <= 1e-13) return 0.0;
        rounds += 1.0;
        out = complex_nonlinear(x);
    }
    return out * rounds;
}

[[nodiscard]] std::uint32_t load_be32(const std::uint8_t* p) noexcept {
    return (static_cast<std::uint32_t>(p[0]) << 24U) |
           (static_cast<std::uint32_t>(p[1]) << 16U) |
           (static_cast<std::uint32_t>(p[2]) << 8U) |
           static_cast<std::uint32_t>(p[3]);
}
} // namespace

std::uint64_t Xoshiro256pp::next() noexcept {
    const std::uint64_t result = std::rotl(s0 + s3, 23) + s0;
    const std::uint64_t t = s1 << 17U;
    s2 ^= s0;
    s3 ^= s1;
    s1 ^= s2;
    s0 ^= s3;
    s2 ^= t;
    s3 = std::rotl(s3, 45);
    return result;
}

Xoshiro256pp make_xoshiro(const Hash256& seed) noexcept {
    return {load_le64(seed.data()), load_le64(seed.data() + 8),
            load_le64(seed.data() + 16), load_le64(seed.data() + 24)};
}

HoohashMatrix generate_hoohash_matrix(const Hash256& seed) {
    HoohashMatrix matrix{};
    auto rng = make_xoshiro(seed);
    constexpr double normalize = 1000000.0;
    for (auto& row : matrix) {
        for (double& cell : row) {
            const auto low = static_cast<std::uint32_t>(rng.next() & 0xffffffffULL);
            cell = static_cast<double>(low) / static_cast<double>(UINT32_MAX) * normalize;
        }
    }
    return matrix;
}

Hash256 hoohash_matrix_mix(const HoohashMatrix& matrix, const Hash256& first_pass, std::uint64_t nonce) {
    std::array<std::uint8_t, 64> vector{};
    std::array<double, 64> product{};
    std::uint32_t hash_mod{};
    for (std::size_t i = 0; i < 8; ++i) hash_mod ^= load_be32(first_pass.data() + i * 4);
    for (std::size_t i = 0; i < 32; ++i) {
        vector[i * 2] = first_pass[i] >> 4U;
        vector[i * 2 + 1] = first_pass[i] & 0x0fU;
    }
    double sw = 0.0;
    const double nonce_mod = static_cast<double>(nonce & 0xffU);
    for (std::size_t i = 0; i < 64; ++i) {
        for (std::size_t j = 0; j < 64; ++j) {
            if (sw <= 0.02) {
                const double input = matrix[i][j] * static_cast<double>(hash_mod) * static_cast<double>(vector[j]) + nonce_mod;
                product[i] += for_complex(input) * static_cast<double>(vector[j]) * 1234.0;
            } else {
                product[i] += matrix[i][j] * 0.0001 * static_cast<double>(vector[j]);
            }
            sw = product[i] / 1024.0 - std::floor(product[i] / 1024.0);
        }
    }
    Hash256 mixed{};
    for (std::size_t i = 0; i < 32; ++i) {
        const auto p = static_cast<std::uint64_t>(product[i * 2]) + static_cast<std::uint64_t>(product[i * 2 + 1]);
        mixed[i] = first_pass[i] ^ static_cast<std::uint8_t>(p & 0xffU);
    }
    return mixed;
}

} // namespace pepepow::crypto
