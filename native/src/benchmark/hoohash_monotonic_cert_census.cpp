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

struct CertStats {
    std::uint64_t attempts{};
    std::uint64_t certified{};
    std::uint64_t certified_cells{};
};

bool same_1024_bin(double a, double b) {
    return static_cast<std::uint64_t>(a / 1024.0) == static_cast<std::uint64_t>(b / 1024.0);
}
} // namespace

int main(int argc, char** argv) {
    std::uint32_t nonce_count = 32768U;
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

    std::array<CertStats, 3> stats{};
    constexpr std::array<int, 3> widths{2, 4, 8};
    std::uint64_t warm_cells = 0, cold_cells = 0, sink = 0;

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
            for (std::size_t col = 0; col < 64; ++col) {
                if (sw > 0.02) {
                    ++warm_cells;
                    for (std::size_t wi = 0; wi < widths.size(); ++wi) {
                        const int w = widths[wi];
                        if (col + static_cast<std::size_t>(w) > 64U) continue;
                        ++stats[wi].attempts;
                        double end = sum;
                        for (int k = 0; k < w; ++k) {
                            const std::size_t c = col + static_cast<std::size_t>(k);
                            end += matrix[row][c] * 0.0001 * static_cast<double>(vector[c]);
                        }
                        if (same_1024_bin(sum, end)) {
                            ++stats[wi].certified;
                            stats[wi].certified_cells += static_cast<std::uint64_t>(w);
                        }
                    }
                    sum += matrix[row][col] * 0.0001 * static_cast<double>(vector[col]);
                } else {
                    ++cold_cells;
                    if (vector[col] != 0U) {
                        const double x = matrix[row][col] * static_cast<double>(hash_mod) * static_cast<double>(vector[col]) + nonce_mod;
                        sum += safe_nonlinear(x) * static_cast<double>(vector[col]) * 1234.0;
                    }
                }
                sw = sum / 1024.0 - std::floor(sum / 1024.0);
            }
            sink ^= static_cast<std::uint64_t>(sum);
        }
    }

    std::cout << std::fixed << std::setprecision(6)
              << "job=hoohash-monotonic-1024-bin-certificate-census\n"
              << "nonces=" << nonce_count << '\n'
              << "warm_cells=" << warm_cells << '\n'
              << "cold_cells=" << cold_cells << '\n';
    for (std::size_t i = 0; i < widths.size(); ++i) {
        const auto& s = stats[i];
        const double hit = s.attempts ? 100.0 * static_cast<double>(s.certified) / static_cast<double>(s.attempts) : 0.0;
        const double coverage = warm_cells ? 100.0 * static_cast<double>(s.certified_cells) / static_cast<double>(warm_cells) : 0.0;
        std::cout << "width_" << widths[i] << "_attempts=" << s.attempts << '\n'
                  << "width_" << widths[i] << "_certified=" << s.certified << '\n'
                  << "width_" << widths[i] << "_certificate_hit_pct=" << hit << '\n'
                  << "width_" << widths[i] << "_potential_warm_cell_coverage_pct=" << coverage << '\n';
    }
    std::cout << "sink=" << sink << '\n';
    return 0;
}
