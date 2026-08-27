#include "pepepow/crypto/blake3.hpp"
#include "pepepow/crypto/hoohash_reference.hpp"

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string_view>

namespace {

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

double pct(std::uint64_t part, std::uint64_t total) {
    return total == 0U ? 0.0 : 100.0 * static_cast<double>(part) / static_cast<double>(total);
}

} // namespace

int main(int argc, char** argv) {
    std::uint32_t nonce_count = 8192U;
    if (argc > 1) nonce_count = static_cast<std::uint32_t>(std::strtoul(argv[1], nullptr, 10));
    if (nonce_count == 0U) {
        std::cerr << "nonce count must be greater than zero\n";
        return 2;
    }

    // Real accepted Header80 vector from the v2.1 consensus validation set.
    constexpr std::string_view kAcceptedHeaderHex =
        "004000206857ad8097ae27f653ff45b867b80e7de26d89f5ca91435a088a1f6200000000"
        "941cfbf2fc87b80ebc90c37b217ade46a9279726e6d0ea9cc1ff93d8d059fc8a"
        "013f676afb24011d00064cd5";

    auto base_header = parse_hex<80>(kAcceptedHeaderHex);
    auto masked_header = base_header;
    std::fill(masked_header.begin() + 76, masked_header.end(), 0U);
    const auto matrix_seed = pepepow::crypto::blake3_hash(masked_header);
    const auto matrix = pepepow::crypto::generate_hoohash_matrix(matrix_seed);

    pepepow::crypto::HooHashNonlinearCensus census{};
    std::uint64_t sink = 0U;
    for (std::uint32_t nonce = 0; nonce < nonce_count; ++nonce) {
        auto header = base_header;
        store_le32(header.data() + 76, nonce);
        const auto first_pass = pepepow::crypto::blake3_hash(header);
        const auto mixed = pepepow::crypto::hoohash_matrix_mix_profiled(
            matrix, first_pass, nonce, census);
        sink ^= mixed[nonce & 31U];
    }

    const auto nonlinear_total = census.nonlinear_branch_counts[0] +
                                 census.nonlinear_branch_counts[1] +
                                 census.nonlinear_branch_counts[2];
    std::cout << std::fixed << std::setprecision(6)
              << "job=accepted-header80-fixed-matrix\n"
              << "nonces=" << census.nonces << '\n'
              << "matrix_cells=" << census.matrix_cells << '\n'
              << "nonlinear_cells=" << census.nonlinear_cells << '\n'
              << "linear_cells=" << census.linear_cells << '\n'
              << "zero_nibble_skips=" << census.zero_nibble_skips << '\n'
              << "nonlinear_cell_pct=" << pct(census.nonlinear_cells, census.matrix_cells) << '\n'
              << "linear_cell_pct=" << pct(census.linear_cells, census.matrix_cells) << '\n'
              << "zero_nibble_skip_pct=" << pct(census.zero_nibble_skips, census.matrix_cells) << '\n'
              << "exp_sincos_count=" << census.nonlinear_branch_counts[0] << '\n'
              << "exp_sincos_pct=" << pct(census.nonlinear_branch_counts[0], nonlinear_total) << '\n'
              << "sin2_count=" << census.nonlinear_branch_counts[1] << '\n'
              << "sin2_pct=" << pct(census.nonlinear_branch_counts[1], nonlinear_total) << '\n'
              << "invsqrt_count=" << census.nonlinear_branch_counts[2] << '\n'
              << "invsqrt_pct=" << pct(census.nonlinear_branch_counts[2], nonlinear_total) << '\n'
              << "transform_add_pct=" << pct(census.transform_counts[0], nonlinear_total) << '\n'
              << "transform_sub_pct=" << pct(census.transform_counts[1], nonlinear_total) << '\n'
              << "transform_mul_pct=" << pct(census.transform_counts[2], nonlinear_total) << '\n'
              << "transform_div_pct=" << pct(census.transform_counts[3], nonlinear_total) << '\n'
              << "retry_rounds=" << census.retry_rounds << '\n'
              << "x_min=" << census.x_min << '\n'
              << "x_max=" << census.x_max << '\n'
              << "exp_sincos_y_min=" << census.y_min[0] << '\n'
              << "exp_sincos_y_max=" << census.y_max[0] << '\n'
              << "sin2_y_min=" << census.y_min[1] << '\n'
              << "sin2_y_max=" << census.y_max[1] << '\n'
              << "invsqrt_y_min=" << census.y_min[2] << '\n'
              << "invsqrt_y_max=" << census.y_max[2] << '\n'
              << "sink=" << sink << '\n';
    return 0;
}
