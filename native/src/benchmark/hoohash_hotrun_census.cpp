#include "pepepow/crypto/blake3.hpp"
#include "pepepow/crypto/hoohash_reference.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string_view>

namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr double kTransformMultiplier = 0.000001;

std::uint8_t hex_nibble(char v) {
    if (v >= '0' && v <= '9') return static_cast<std::uint8_t>(v - '0');
    if (v >= 'a' && v <= 'f') return static_cast<std::uint8_t>(v - 'a' + 10);
    if (v >= 'A' && v <= 'F') return static_cast<std::uint8_t>(v - 'A' + 10);
    throw std::invalid_argument("invalid hex digit");
}

template <std::size_t N>
std::array<std::uint8_t, N> parse_hex(std::string_view text) {
    if (text.size() != N * 2U) throw std::invalid_argument("unexpected hex length");
    std::array<std::uint8_t, N> out{};
    for (std::size_t i = 0; i < N; ++i)
        out[i] = static_cast<std::uint8_t>((hex_nibble(text[i * 2]) << 4U) | hex_nibble(text[i * 2 + 1]));
    return out;
}

void store_le32(std::uint8_t* out, std::uint32_t value) {
    out[0] = static_cast<std::uint8_t>(value);
    out[1] = static_cast<std::uint8_t>(value >> 8U);
    out[2] = static_cast<std::uint8_t>(value >> 16U);
    out[3] = static_cast<std::uint8_t>(value >> 24U);
}

std::uint32_t load_be32(const std::uint8_t* p) {
    return (static_cast<std::uint32_t>(p[0]) << 24U) |
           (static_cast<std::uint32_t>(p[1]) << 16U) |
           (static_cast<std::uint32_t>(p[2]) << 8U) |
           static_cast<std::uint32_t>(p[3]);
}

double nonlinear(double x) {
    const double one = x * kTransformMultiplier / 8.0 - std::floor(x * kTransformMultiplier / 8.0);
    const double two = x * kTransformMultiplier / 4.0 - std::floor(x * kTransformMultiplier / 4.0);
    double y{};
    if (two < 0.25) y = x + (1.0 + two);
    else if (two < 0.50) y = x - (1.0 + two);
    else if (two < 0.75) y = x * (1.0 + two);
    else y = x / (1.0 + two);
    if (one < 0.33) return std::exp(std::sin(y) + std::cos(y));
    if (one < 0.66) {
        if (y == kPi / 2.0 || y == 3.0 * kPi / 2.0) return 0.0;
        const double s = std::sin(y); return s * s;
    }
    return 1.0 / std::sqrt(std::fabs(y) + 1.0);
}

double safe_nonlinear(double x) {
    double rounds = 1.0;
    double out = nonlinear(x);
    while (std::isnan(out) || std::isinf(out)) {
        x *= 0.1;
        if (x <= 1e-13) return 0.0;
        rounds += 1.0;
        out = nonlinear(x);
    }
    return out * rounds;
}

struct Runs {
    std::array<std::uint64_t, 65> hist{};
    std::uint64_t linear_cells{};
    std::uint64_t cold_cells{};
    std::uint64_t zero_cold{};
    std::uint64_t runs{};
    std::uint64_t max_run{};
};

void flush_run(Runs& r, std::uint32_t len) {
    if (!len) return;
    ++r.runs;
    r.max_run = std::max<std::uint64_t>(r.max_run, len);
    ++r.hist[std::min<std::uint32_t>(len, 64U)];
}

std::uint64_t chunk_steps(const Runs& r, std::uint32_t width) {
    std::uint64_t n = 0;
    for (std::uint32_t len = 1; len <= 64; ++len)
        n += r.hist[len] * ((len + width - 1U) / width);
    return n;
}

double reduction(std::uint64_t baseline, std::uint64_t reduced) {
    return baseline ? 100.0 * (1.0 - static_cast<double>(reduced) / static_cast<double>(baseline)) : 0.0;
}
} // namespace

int main(int argc, char** argv) {
    std::uint32_t nonce_count = 8192U;
    if (argc > 1) nonce_count = static_cast<std::uint32_t>(std::strtoul(argv[1], nullptr, 10));
    if (!nonce_count) return 2;

    constexpr std::string_view kAcceptedHeaderHex =
        "004000206857ad8097ae27f653ff45b867b80e7de26d89f5ca91435a088a1f6200000000"
        "941cfbf2fc87b80ebc90c37b217ade46a9279726e6d0ea9cc1ff93d8d059fc8a"
        "013f676afb24011d00064cd5";
    auto base = parse_hex<80>(kAcceptedHeaderHex);
    auto masked = base;
    std::fill(masked.begin() + 76, masked.end(), 0U);
    const auto matrix = pepepow::crypto::generate_hoohash_matrix(pepepow::crypto::blake3_hash(masked));

    Runs runs{};
    std::uint64_t sink = 0;
    for (std::uint32_t nonce = 0; nonce < nonce_count; ++nonce) {
        auto header = base;
        store_le32(header.data() + 76, nonce);
        const auto first = pepepow::crypto::blake3_hash(header);
        std::array<std::uint8_t, 64> vector{};
        std::uint32_t hash_mod = 0;
        for (std::size_t i = 0; i < 8; ++i) hash_mod ^= load_be32(first.data() + i * 4);
        for (std::size_t i = 0; i < 32; ++i) {
            vector[i * 2] = first[i] >> 4U;
            vector[i * 2 + 1] = first[i] & 0x0fU;
        }
        double sw = 0.0;
        const double nonce_mod = static_cast<double>(nonce & 0xffU);
        for (std::size_t row = 0; row < 64; ++row) {
            double sum = 0.0;
            std::uint32_t hot_run = 0;
            for (std::size_t col = 0; col < 64; ++col) {
                if (sw <= 0.02) {
                    flush_run(runs, hot_run); hot_run = 0;
                    ++runs.cold_cells;
                    if (vector[col] == 0U) ++runs.zero_cold;
                    else {
                        const double x = matrix[row][col] * static_cast<double>(hash_mod) * static_cast<double>(vector[col]) + nonce_mod;
                        sum += safe_nonlinear(x) * static_cast<double>(vector[col]) * 1234.0;
                    }
                } else {
                    ++hot_run;
                    ++runs.linear_cells;
                    sum += matrix[row][col] * 0.0001 * static_cast<double>(vector[col]);
                }
                sw = sum / 1024.0 - std::floor(sum / 1024.0);
            }
            flush_run(runs, hot_run);
            sink ^= static_cast<std::uint64_t>(sum);
        }
    }

    std::cout << std::fixed << std::setprecision(6)
              << "job=accepted-header80-hotrun-prefix-census\n"
              << "nonces=" << nonce_count << '\n'
              << "linear_cells=" << runs.linear_cells << '\n'
              << "cold_cells=" << runs.cold_cells << '\n'
              << "zero_cold=" << runs.zero_cold << '\n'
              << "linear_runs=" << runs.runs << '\n'
              << "max_linear_run=" << runs.max_run << '\n';
    for (std::uint32_t w : {4U, 8U, 16U, 32U}) {
        const auto steps = chunk_steps(runs, w);
        std::cout << "prefix_width_" << w << "_chunk_steps=" << steps << '\n'
                  << "prefix_width_" << w << "_linear_state_step_reduction_pct="
                  << reduction(runs.linear_cells, steps) << '\n';
    }
    for (std::uint32_t len : {1U, 2U, 4U, 8U, 16U, 32U, 64U}) {
        std::uint64_t at_least = 0;
        for (std::uint32_t k = len; k <= 64; ++k) at_least += runs.hist[k];
        std::cout << "runs_ge_" << len << '=' << at_least << '\n';
    }
    std::cout << "sink=" << sink << '\n';
    return 0;
}
