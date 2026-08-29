#include "pepepow/crypto/blake3.hpp"
#include "pepepow/crypto/hoohash_reference.hpp"

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string_view>

namespace {
using pepepow::crypto::Hash256;
using pepepow::crypto::HoohashMatrix;

constexpr double kPi = 3.14159265358979323846;
constexpr double kEpsilon = 1e-9;
constexpr double kTransformMultiplier = 0.000001;

struct Range {
    double lo = std::numeric_limits<double>::infinity();
    double hi = -std::numeric_limits<double>::infinity();
    void add(double v) noexcept {
        if (v < lo) lo = v;
        if (v > hi) hi = v;
    }
};

struct Census {
    std::uint64_t total_cells{};
    std::uint64_t cold_cells{};
    std::uint64_t warm_cells{};
    std::uint64_t cold_zero_nibble{};
    std::uint64_t nonlinear_calls{};
    std::uint64_t medium_calls{};
    std::uint64_t intermediate_calls{};
    std::uint64_t high_calls{};
    std::uint64_t transform_add{};
    std::uint64_t transform_sub{};
    std::uint64_t transform_mul{};
    std::uint64_t transform_div{};
    std::uint64_t nonfinite_first{};
    std::uint64_t nonfinite_retry_iterations{};
    std::uint64_t intermediate_pi_guard{};
    Range x_all, y_all, x_medium, y_medium, x_intermediate, y_intermediate, x_high, y_high;
};

std::uint8_t hex_nibble(char c) {
    if (c >= '0' && c <= '9') return static_cast<std::uint8_t>(c - '0');
    if (c >= 'a' && c <= 'f') return static_cast<std::uint8_t>(c - 'a' + 10);
    if (c >= 'A' && c <= 'F') return static_cast<std::uint8_t>(c - 'A' + 10);
    throw std::runtime_error("bad hex");
}

template <std::size_t N>
std::array<std::uint8_t, N> parse_hex(std::string_view s) {
    if (s.size() != N * 2U) throw std::runtime_error("bad hex length");
    std::array<std::uint8_t, N> out{};
    for (std::size_t i = 0; i < N; ++i) {
        out[i] = static_cast<std::uint8_t>((hex_nibble(s[i * 2U]) << 4U) | hex_nibble(s[i * 2U + 1U]));
    }
    return out;
}

void store_le32(std::uint8_t* p, std::uint32_t x) noexcept {
    p[0] = static_cast<std::uint8_t>(x);
    p[1] = static_cast<std::uint8_t>(x >> 8U);
    p[2] = static_cast<std::uint8_t>(x >> 16U);
    p[3] = static_cast<std::uint8_t>(x >> 24U);
}

std::uint32_t load_be32(const std::uint8_t* p) noexcept {
    return (static_cast<std::uint32_t>(p[0]) << 24U) |
           (static_cast<std::uint32_t>(p[1]) << 16U) |
           (static_cast<std::uint32_t>(p[2]) << 8U) |
           static_cast<std::uint32_t>(p[3]);
}

double profiled_nonlinear(double x, Census& c) {
    c.nonlinear_calls++;
    c.x_all.add(x);
    const double one = x * kTransformMultiplier / 8.0 - std::floor(x * kTransformMultiplier / 8.0);
    const double two = x * kTransformMultiplier / 4.0 - std::floor(x * kTransformMultiplier / 4.0);
    double y{};
    if (two < 0.25) {
        ++c.transform_add;
        y = x + 1.0 + two;
    } else if (two < 0.50) {
        ++c.transform_sub;
        y = x - 1.0 - two;
    } else if (two < 0.75) {
        ++c.transform_mul;
        y = x * (1.0 + two);
    } else {
        ++c.transform_div;
        y = x / (1.0 + two);
    }
    c.y_all.add(y);
    if (one < 0.33) {
        ++c.medium_calls;
        c.x_medium.add(x); c.y_medium.add(y);
        return std::exp(std::sin(y) + std::cos(y));
    }
    if (one < 0.66) {
        ++c.intermediate_calls;
        c.x_intermediate.add(x); c.y_intermediate.add(y);
        if (std::fabs(y - kPi / 2.0) < kEpsilon || std::fabs(y - 3.0 * kPi / 2.0) < kEpsilon) {
            ++c.intermediate_pi_guard;
            return 0.0;
        }
        const double s = std::sin(y);
        return s * s;
    }
    ++c.high_calls;
    c.x_high.add(x); c.y_high.add(y);
    return 1.0 / std::sqrt(std::fabs(y) + 1.0);
}

double profiled_safe_nonlinear(double input, Census& c) {
    double rounds = 1.0;
    double x = input;
    double out = profiled_nonlinear(x, c);
    if (std::isnan(out) || std::isinf(out)) ++c.nonfinite_first;
    while (std::isnan(out) || std::isinf(out)) {
        x *= 0.1;
        if (x <= 1e-13) return 0.0;
        rounds += 1.0;
        ++c.nonfinite_retry_iterations;
        out = profiled_nonlinear(x, c);
    }
    return out * rounds;
}

void census_mix(const HoohashMatrix& matrix, const Hash256& first_pass, std::uint32_t nonce, Census& c) {
    std::array<std::uint8_t, 64> vector{};
    std::array<double, 64> product{};
    std::uint32_t hash_mod{};
    for (std::size_t i = 0; i < 8; ++i) hash_mod ^= load_be32(first_pass.data() + i * 4U);
    for (std::size_t i = 0; i < 32; ++i) {
        vector[i * 2U] = first_pass[i] >> 4U;
        vector[i * 2U + 1U] = first_pass[i] & 0x0fU;
    }
    double sw = 0.0;
    const double nonce_mod = static_cast<double>(nonce & 0xffU);
    for (std::size_t i = 0; i < 64; ++i) {
        for (std::size_t j = 0; j < 64; ++j) {
            ++c.total_cells;
            const auto nib = vector[j];
            if (sw <= 0.02) {
                ++c.cold_cells;
                if (nib == 0U) {
                    ++c.cold_zero_nibble;
                } else {
                    const double val = static_cast<double>(nib);
                    const double x = matrix[i][j] * static_cast<double>(hash_mod) * val + nonce_mod;
                    product[i] += profiled_safe_nonlinear(x, c) * val * 1234.0;
                }
            } else {
                ++c.warm_cells;
                product[i] += matrix[i][j] * 0.0001 * static_cast<double>(nib);
            }
            sw = product[i] / 1024.0 - std::floor(product[i] / 1024.0);
        }
    }
}

void print_range(const char* name, const Range& r) {
    std::cout << name << "_min=" << r.lo << '\n';
    std::cout << name << "_max=" << r.hi << '\n';
}

double pct(std::uint64_t n, std::uint64_t d) {
    return d ? 100.0 * static_cast<double>(n) / static_cast<double>(d) : 0.0;
}

} // namespace

int main(int argc, char** argv) {
    std::uint32_t count = 4096U;
    if (argc > 1) count = static_cast<std::uint32_t>(std::strtoul(argv[1], nullptr, 10));
    if (count == 0U) return 2;

    constexpr std::string_view hex = "004000206857ad8097ae27f653ff45b867b80e7de26d89f5ca91435a088a1f6200000000941cfbf2fc87b80ebc90c37b217ade46a9279726e6d0ea9cc1ff93d8d059fc8a013f676afb24011d00064cd5";
    auto base = parse_hex<80>(hex);
    auto masked = base;
    for (int i = 76; i < 80; ++i) masked[static_cast<std::size_t>(i)] = 0;
    const auto seed = pepepow::crypto::blake3_hash(masked);
    const auto matrix = pepepow::crypto::generate_hoohash_matrix(seed);

    Census c{};
    for (std::uint32_t nonce = 0; nonce < count; ++nonce) {
        auto header = base;
        store_le32(header.data() + 76, nonce);
        const auto first = pepepow::crypto::blake3_hash(header);
        census_mix(matrix, first, nonce, c);
    }

    std::cout << std::fixed << std::setprecision(6);
    std::cout << "profile=exact_v21_nonlinear_census\n";
    std::cout << "nonces=" << count << '\n';
    std::cout << "total_cells=" << c.total_cells << '\n';
    std::cout << "cold_cells=" << c.cold_cells << '\n';
    std::cout << "warm_cells=" << c.warm_cells << '\n';
    std::cout << "cold_pct=" << pct(c.cold_cells, c.total_cells) << '\n';
    std::cout << "warm_pct=" << pct(c.warm_cells, c.total_cells) << '\n';
    std::cout << "cold_zero_nibble=" << c.cold_zero_nibble << '\n';
    std::cout << "nonlinear_calls=" << c.nonlinear_calls << '\n';
    std::cout << "medium_calls=" << c.medium_calls << '\n';
    std::cout << "intermediate_calls=" << c.intermediate_calls << '\n';
    std::cout << "high_calls=" << c.high_calls << '\n';
    std::cout << "medium_pct=" << pct(c.medium_calls, c.nonlinear_calls) << '\n';
    std::cout << "intermediate_pct=" << pct(c.intermediate_calls, c.nonlinear_calls) << '\n';
    std::cout << "high_pct=" << pct(c.high_calls, c.nonlinear_calls) << '\n';
    std::cout << "transform_add=" << c.transform_add << '\n';
    std::cout << "transform_sub=" << c.transform_sub << '\n';
    std::cout << "transform_mul=" << c.transform_mul << '\n';
    std::cout << "transform_div=" << c.transform_div << '\n';
    std::cout << "transform_add_pct=" << pct(c.transform_add, c.nonlinear_calls) << '\n';
    std::cout << "transform_sub_pct=" << pct(c.transform_sub, c.nonlinear_calls) << '\n';
    std::cout << "transform_mul_pct=" << pct(c.transform_mul, c.nonlinear_calls) << '\n';
    std::cout << "transform_div_pct=" << pct(c.transform_div, c.nonlinear_calls) << '\n';
    std::cout << "nonfinite_first=" << c.nonfinite_first << '\n';
    std::cout << "nonfinite_retry_iterations=" << c.nonfinite_retry_iterations << '\n';
    std::cout << "intermediate_pi_guard=" << c.intermediate_pi_guard << '\n';
    print_range("x_all", c.x_all); print_range("y_all", c.y_all);
    print_range("x_medium", c.x_medium); print_range("y_medium", c.y_medium);
    print_range("x_intermediate", c.x_intermediate); print_range("y_intermediate", c.y_intermediate);
    print_range("x_high", c.x_high); print_range("y_high", c.y_high);
    return 0;
}
