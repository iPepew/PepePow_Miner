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
#include <limits>
#include <stdexcept>
#include <string_view>

namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr double kTransformMultiplier = 0.000001;

std::uint8_t hex_nibble(char value) {
    if (value >= '0' && value <= '9') return static_cast<std::uint8_t>(value - '0');
    if (value >= 'a' && value <= 'f') return static_cast<std::uint8_t>(value - 'a' + 10);
    if (value >= 'A' && value <= 'F') return static_cast<std::uint8_t>(value - 'A' + 10);
    throw std::invalid_argument("invalid hex digit");
}

template <std::size_t N>
std::array<std::uint8_t, N> parse_hex(std::string_view text) {
    if (text.size() != N * 2U) throw std::invalid_argument("unexpected hex length");
    std::array<std::uint8_t, N> output{};
    for (std::size_t index = 0; index < N; ++index) {
        output[index] = static_cast<std::uint8_t>(
            (hex_nibble(text[index * 2U]) << 4U) | hex_nibble(text[index * 2U + 1U]));
    }
    return output;
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

double medium(double x) { return std::exp(std::sin(x) + std::cos(x)); }
double intermediate(double x) {
    if (x == kPi / 2.0 || x == 3.0 * kPi / 2.0) return 0.0;
    const double s = std::sin(x);
    return s * s;
}
double high(double x) { return 1.0 / std::sqrt(std::fabs(x) + 1.0); }

double complex_nonlinear(double x) {
    const double one = x * kTransformMultiplier / 8.0 - std::floor(x * kTransformMultiplier / 8.0);
    const double two = x * kTransformMultiplier / 4.0 - std::floor(x * kTransformMultiplier / 4.0);
    double y{};
    if (two < 0.25) y = x + (1.0 + two);
    else if (two < 0.50) y = x - (1.0 + two);
    else if (two < 0.75) y = x * (1.0 + two);
    else y = x / (1.0 + two);
    if (one < 0.33) return medium(y);
    if (one < 0.66) return intermediate(y);
    return high(y);
}

double for_complex(double x) {
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

double pct(std::uint64_t part, std::uint64_t total) {
    return total == 0U ? 0.0 : 100.0 * static_cast<double>(part) / static_cast<double>(total);
}

struct Census {
    std::uint64_t nonces{};
    std::uint64_t mismatches{};
    std::uint64_t rows{};
    std::uint64_t rows_start_cold{};
    std::uint64_t rows_start_warm{};
    std::uint64_t rows_without_nonlinear{};
    std::uint64_t rows_with_nonlinear{};
    std::uint64_t nonlinear_cells{};
    std::uint64_t linear_cells{};
    std::uint64_t cold_zero_cells{};
    std::uint64_t cold_episodes{};
    std::uint64_t cold_episode_cells{};
    std::uint64_t longest_cold_episode{};
    std::uint64_t longest_linear_run{};
    std::array<std::uint64_t, 65> first_nonlinear_col{}; // 64 = none
    std::array<std::uint64_t, 65> nonlinear_per_row{};
    std::array<std::uint64_t, 65> longest_linear_run_per_row{};
    std::array<std::uint64_t, 3> segments_total{};       // widths 8,16,32
    std::array<std::uint64_t, 3> segments_no_nonlinear{};
    std::array<std::uint64_t, 3> cells_in_no_nonlinear_segments{};
};

pepepow::crypto::Hash256 profiled_mix(
    const pepepow::crypto::HoohashMatrix& matrix,
    const pepepow::crypto::Hash256& first_pass,
    std::uint64_t nonce,
    Census& census) {
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
    constexpr std::array<std::size_t, 3> widths{8U, 16U, 32U};

    for (std::size_t row = 0; row < 64; ++row) {
        ++census.rows;
        if (sw <= 0.02) ++census.rows_start_cold;
        else ++census.rows_start_warm;

        std::array<bool, 64> nonlinear_mask{};
        std::size_t row_nonlinear = 0U;
        std::size_t first_nonlinear = 64U;
        std::size_t current_linear_run = 0U;
        std::size_t row_longest_linear_run = 0U;
        std::size_t current_cold_episode = 0U;

        for (std::size_t col = 0; col < 64; ++col) {
            const bool cold = sw <= 0.02;
            bool nonlinear = false;
            if (cold) {
                ++current_cold_episode;
                if (vector[col] == 0U) {
                    ++census.cold_zero_cells;
                } else {
                    nonlinear = true;
                    nonlinear_mask[col] = true;
                    ++census.nonlinear_cells;
                    ++row_nonlinear;
                    if (first_nonlinear == 64U) first_nonlinear = col;
                    const double value = static_cast<double>(vector[col]);
                    const double input = matrix[row][col] * static_cast<double>(hash_mod) * value + nonce_mod;
                    product[row] += for_complex(input) * value * 1234.0;
                }
            } else {
                if (current_cold_episode != 0U) {
                    ++census.cold_episodes;
                    census.cold_episode_cells += current_cold_episode;
                    census.longest_cold_episode = std::max<std::uint64_t>(census.longest_cold_episode, current_cold_episode);
                    current_cold_episode = 0U;
                }
                ++census.linear_cells;
                product[row] += matrix[row][col] * 0.0001 * static_cast<double>(vector[col]);
            }

            if (nonlinear) {
                row_longest_linear_run = std::max(row_longest_linear_run, current_linear_run);
                current_linear_run = 0U;
            } else {
                ++current_linear_run;
            }
            sw = product[row] / 1024.0 - std::floor(product[row] / 1024.0);
        }
        if (current_cold_episode != 0U) {
            ++census.cold_episodes;
            census.cold_episode_cells += current_cold_episode;
            census.longest_cold_episode = std::max<std::uint64_t>(census.longest_cold_episode, current_cold_episode);
        }
        row_longest_linear_run = std::max(row_longest_linear_run, current_linear_run);
        census.longest_linear_run = std::max<std::uint64_t>(census.longest_linear_run, row_longest_linear_run);
        ++census.first_nonlinear_col[first_nonlinear];
        ++census.nonlinear_per_row[row_nonlinear];
        ++census.longest_linear_run_per_row[row_longest_linear_run];
        if (row_nonlinear == 0U) ++census.rows_without_nonlinear;
        else ++census.rows_with_nonlinear;

        for (std::size_t wi = 0; wi < widths.size(); ++wi) {
            const std::size_t width = widths[wi];
            for (std::size_t begin = 0; begin < 64; begin += width) {
                ++census.segments_total[wi];
                bool has_nonlinear = false;
                for (std::size_t col = begin; col < begin + width; ++col) {
                    has_nonlinear = has_nonlinear || nonlinear_mask[col];
                }
                if (!has_nonlinear) {
                    ++census.segments_no_nonlinear[wi];
                    census.cells_in_no_nonlinear_segments[wi] += width;
                }
            }
        }
    }

    pepepow::crypto::Hash256 mixed{};
    for (std::size_t i = 0; i < 32; ++i) {
        const auto p = static_cast<std::uint64_t>(product[i * 2]) + static_cast<std::uint64_t>(product[i * 2 + 1]);
        mixed[i] = first_pass[i] ^ static_cast<std::uint8_t>(p & 0xffU);
    }
    return mixed;
}

} // namespace

int main(int argc, char** argv) {
    std::uint32_t nonce_count = 32768U;
    if (argc > 1) nonce_count = static_cast<std::uint32_t>(std::strtoul(argv[1], nullptr, 10));
    if (nonce_count == 0U) return 2;

    constexpr std::string_view kAcceptedHeaderHex =
        "004000206857ad8097ae27f653ff45b867b80e7de26d89f5ca91435a088a1f6200000000"
        "941cfbf2fc87b80ebc90c37b217ade46a9279726e6d0ea9cc1ff93d8d059fc8a"
        "013f676afb24011d00064cd5";
    auto base_header = parse_hex<80>(kAcceptedHeaderHex);
    auto masked_header = base_header;
    std::fill(masked_header.begin() + 76, masked_header.end(), 0U);
    const auto matrix_seed = pepepow::crypto::blake3_hash(masked_header);
    const auto matrix = pepepow::crypto::generate_hoohash_matrix(matrix_seed);

    Census census{};
    for (std::uint32_t nonce = 0; nonce < nonce_count; ++nonce) {
        auto header = base_header;
        store_le32(header.data() + 76, nonce);
        const auto first_pass = pepepow::crypto::blake3_hash(header);
        const auto strict = pepepow::crypto::hoohash_matrix_mix(matrix, first_pass, nonce);
        const auto observed = profiled_mix(matrix, first_pass, nonce, census);
        ++census.nonces;
        if (strict != observed) ++census.mismatches;
    }

    const std::uint64_t cells = census.rows * 64U;
    std::cout << std::fixed << std::setprecision(6)
              << "job=accepted-header80-fixed-matrix\n"
              << "nonces=" << census.nonces << '\n'
              << "mismatches=" << census.mismatches << '\n'
              << "rows=" << census.rows << '\n'
              << "rows_start_cold_pct=" << pct(census.rows_start_cold, census.rows) << '\n'
              << "rows_start_warm_pct=" << pct(census.rows_start_warm, census.rows) << '\n'
              << "rows_without_nonlinear_pct=" << pct(census.rows_without_nonlinear, census.rows) << '\n'
              << "rows_with_nonlinear_pct=" << pct(census.rows_with_nonlinear, census.rows) << '\n'
              << "nonlinear_cell_pct=" << pct(census.nonlinear_cells, cells) << '\n'
              << "linear_cell_pct=" << pct(census.linear_cells, cells) << '\n'
              << "cold_zero_cell_pct=" << pct(census.cold_zero_cells, cells) << '\n'
              << "avg_nonlinear_cells_per_nonce=" << static_cast<double>(census.nonlinear_cells) / census.nonces << '\n'
              << "avg_cold_episodes_per_nonce=" << static_cast<double>(census.cold_episodes) / census.nonces << '\n'
              << "avg_cold_episode_cells=" << (census.cold_episodes ? static_cast<double>(census.cold_episode_cells) / census.cold_episodes : 0.0) << '\n'
              << "longest_cold_episode=" << census.longest_cold_episode << '\n'
              << "longest_no_nonlinear_run=" << census.longest_linear_run << '\n'
              << "first_nonlinear_col_none_pct=" << pct(census.first_nonlinear_col[64], census.rows) << '\n'
              << "first_nonlinear_col_0_7_pct=" << pct(census.first_nonlinear_col[0]+census.first_nonlinear_col[1]+census.first_nonlinear_col[2]+census.first_nonlinear_col[3]+census.first_nonlinear_col[4]+census.first_nonlinear_col[5]+census.first_nonlinear_col[6]+census.first_nonlinear_col[7], census.rows) << '\n'
              << "segment8_no_nonlinear_pct=" << pct(census.segments_no_nonlinear[0], census.segments_total[0]) << '\n'
              << "segment16_no_nonlinear_pct=" << pct(census.segments_no_nonlinear[1], census.segments_total[1]) << '\n'
              << "segment32_no_nonlinear_pct=" << pct(census.segments_no_nonlinear[2], census.segments_total[2]) << '\n'
              << "cells_covered_by_clean_segment8_pct=" << pct(census.cells_in_no_nonlinear_segments[0], cells) << '\n'
              << "cells_covered_by_clean_segment16_pct=" << pct(census.cells_in_no_nonlinear_segments[1], cells) << '\n'
              << "cells_covered_by_clean_segment32_pct=" << pct(census.cells_in_no_nonlinear_segments[2], cells) << '\n';

    std::cout << "nonlinear_per_row_hist=";
    for (std::size_t i = 0; i < census.nonlinear_per_row.size(); ++i) {
        if (census.nonlinear_per_row[i] != 0U) std::cout << i << ':' << census.nonlinear_per_row[i] << ',';
    }
    std::cout << '\n';
    return census.mismatches == 0U ? 0 : 3;
}
