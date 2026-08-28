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
#include <vector>

namespace {

using pepepow::crypto::Hash256;
using pepepow::crypto::HoohashMatrix;

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
        output[index] = static_cast<std::uint8_t>((hex_nibble(text[index * 2U]) << 4U) |
                                                  hex_nibble(text[index * 2U + 1U]));
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

bool relaxed_hit(const Hash256& hash, unsigned target_bits) {
    const unsigned full_bytes = target_bits / 8U;
    const unsigned rem_bits = target_bits % 8U;
    for (unsigned i = 0; i < full_bytes; ++i) {
        if (hash[i] != 0U) return false;
    }
    if (rem_bits == 0U) return true;
    const std::uint8_t mask = static_cast<std::uint8_t>(0xffU << (8U - rem_bits));
    return (hash[full_bytes] & mask) == 0U;
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
        const double s = std::sin(y);
        return s * s;
    }
    return 1.0 / std::sqrt(std::fabs(y) + 1.0);
}

double safe_nonlinear(double x) {
    double rounds = 1.0;
    double result = nonlinear(x);
    while (std::isnan(result) || std::isinf(result)) {
        x *= 0.1;
        if (x <= 1e-13) return 0.0;
        rounds += 1.0;
        result = nonlinear(x);
    }
    return result * rounds;
}

struct MixStats {
    Hash256 mixed{};
    std::uint64_t nonlinear_cells{};
};

MixStats instrumented_mix(const HoohashMatrix& matrix, const Hash256& first_pass, std::uint64_t nonce) {
    std::array<std::uint8_t, 64> vector{};
    std::array<double, 64> product{};
    std::uint32_t hash_mod{};
    for (std::size_t i = 0; i < 8; ++i) hash_mod ^= load_be32(first_pass.data() + i * 4U);
    for (std::size_t i = 0; i < 32; ++i) {
        vector[i * 2U] = first_pass[i] >> 4U;
        vector[i * 2U + 1U] = first_pass[i] & 0x0fU;
    }

    std::uint64_t nonlinear_cells = 0U;
    double sw = 0.0;
    const double nonce_mod = static_cast<double>(nonce & 0xffU);
    for (std::size_t row = 0; row < 64; ++row) {
        for (std::size_t col = 0; col < 64; ++col) {
            if (sw <= 0.02) {
                ++nonlinear_cells;
                if (vector[col] != 0U) {
                    const double x = matrix[row][col] * static_cast<double>(hash_mod) *
                                     static_cast<double>(vector[col]) + nonce_mod;
                    product[row] += safe_nonlinear(x) * static_cast<double>(vector[col]) * 1234.0;
                }
            } else {
                product[row] += matrix[row][col] * 0.0001 * static_cast<double>(vector[col]);
            }
            sw = product[row] / 1024.0 - std::floor(product[row] / 1024.0);
        }
    }

    Hash256 mixed{};
    for (std::size_t i = 0; i < 32; ++i) {
        const auto p = static_cast<std::uint64_t>(product[i * 2U]) +
                       static_cast<std::uint64_t>(product[i * 2U + 1U]);
        mixed[i] = first_pass[i] ^ static_cast<std::uint8_t>(p & 0xffU);
    }
    return {mixed, nonlinear_cells};
}

std::uint64_t mix64(std::uint64_t x) {
    x += 0x9e3779b97f4a7c15ULL;
    x = (x ^ (x >> 30U)) * 0xbf58476d1ce4e5b9ULL;
    x = (x ^ (x >> 27U)) * 0x94d049bb133111ebULL;
    return x ^ (x >> 31U);
}

} // namespace

int main(int argc, char** argv) {
    std::uint32_t nonce_count = 32768U;
    unsigned target_bits = 4U;
    if (argc > 1) nonce_count = static_cast<std::uint32_t>(std::strtoul(argv[1], nullptr, 10));
    if (argc > 2) target_bits = static_cast<unsigned>(std::strtoul(argv[2], nullptr, 10));
    if (nonce_count == 0U || target_bits == 0U || target_bits > 8U) {
        std::cerr << "usage: hoohash_speculative_error_budget [nonces>0] [target_bits 1..8]\n";
        return 2;
    }

    constexpr std::string_view kAcceptedHeaderHex =
        "004000206857ad8097ae27f653ff45b867b80e7de26d89f5ca91435a088a1f6200000000"
        "941cfbf2fc87b80ebc90c37b217ade46a9279726e6d0ea9cc1ff93d8d059fc8a"
        "013f676afb24011d00064cd5";

    auto base_header = parse_hex<80>(kAcceptedHeaderHex);
    auto masked_header = base_header;
    std::fill(masked_header.begin() + 76, masked_header.end(), 0U);
    const auto matrix_seed = pepepow::crypto::blake3_hash(masked_header);
    const auto matrix = pepepow::crypto::generate_hoohash_matrix(matrix_seed);

    std::vector<Hash256> strict_mixed(nonce_count);
    std::vector<std::uint8_t> strict_hit(nonce_count, 0U);
    std::uint64_t strict_hits = 0U;
    std::uint64_t nonlinear_cells = 0U;
    std::uint64_t reference_mismatches = 0U;

    for (std::uint32_t nonce = 0; nonce < nonce_count; ++nonce) {
        auto header = base_header;
        store_le32(header.data() + 76, nonce);
        const auto first_pass = pepepow::crypto::blake3_hash(header);
        const auto measured = instrumented_mix(matrix, first_pass, nonce);
        strict_mixed[nonce] = measured.mixed;
        nonlinear_cells += measured.nonlinear_cells;

        if (nonce < std::min<std::uint32_t>(nonce_count, 2048U)) {
            const auto reference = pepepow::crypto::hoohash_matrix_mix(matrix, first_pass, nonce);
            if (reference != measured.mixed) ++reference_mismatches;
        }

        const auto final_hash = pepepow::crypto::blake3_hash(measured.mixed);
        if (relaxed_hit(final_hash, target_bits)) {
            strict_hit[nonce] = 1U;
            ++strict_hits;
        }
    }

    if (reference_mismatches != 0U) {
        std::cerr << "reference_mismatches=" << reference_mismatches << '\n';
        return 3;
    }

    const double nonlinear_per_nonce = static_cast<double>(nonlinear_cells) / static_cast<double>(nonce_count);
    const double max_nonce_mismatch = 0.005;
    const double max_cell_error_all = 1.0 - std::pow(1.0 - max_nonce_mismatch, 1.0 / 4096.0);
    const double max_cell_error_nonlinear = nonlinear_per_nonce > 0.0
        ? 1.0 - std::pow(1.0 - max_nonce_mismatch, 1.0 / nonlinear_per_nonce)
        : 0.0;

    std::cout << std::fixed << std::setprecision(9)
              << "job=accepted-header80-speculative-error-budget\n"
              << "nonces=" << nonce_count << '\n'
              << "relaxed_target_bits=" << target_bits << '\n'
              << "reference_mismatches=" << reference_mismatches << '\n'
              << "strict_hits=" << strict_hits << '\n'
              << "nonlinear_cells=" << nonlinear_cells << '\n'
              << "nonlinear_cells_per_nonce=" << nonlinear_per_nonce << '\n'
              << "max_independent_cell_error_for_99_5pct_nonce_equality_all_cells=" << max_cell_error_all << '\n'
              << "max_independent_cell_error_for_99_5pct_nonce_equality_nonlinear_cells=" << max_cell_error_nonlinear << '\n';

    constexpr std::array<unsigned, 7> fault_per_million{500U, 1000U, 2500U, 5000U, 10000U, 20000U, 50000U};
    bool avalanche_consistent = true;
    for (unsigned ppm : fault_per_million) {
        std::uint64_t changed_nonces = 0U;
        std::uint64_t fast_hits = 0U;
        std::uint64_t tp = 0U;
        std::uint64_t fn = 0U;
        std::uint64_t fp = 0U;

        for (std::uint32_t nonce = 0; nonce < nonce_count; ++nonce) {
            Hash256 mixed = strict_mixed[nonce];
            const bool fault = (mix64(nonce) % 1000000ULL) < ppm;
            if (fault) {
                ++changed_nonces;
                const std::size_t byte = static_cast<std::size_t>(mix64(static_cast<std::uint64_t>(nonce) ^ 0xa5a5a5a5ULL) & 31ULL);
                mixed[byte] ^= 0x01U;
            }

            const bool fast = relaxed_hit(pepepow::crypto::blake3_hash(mixed), target_bits);
            const bool strict = strict_hit[nonce] != 0U;
            if (fast) ++fast_hits;
            if (fast && strict) ++tp;
            if (!fast && strict) ++fn;
            if (fast && !strict) ++fp;
        }

        const double changed_fraction = static_cast<double>(changed_nonces) / static_cast<double>(nonce_count);
        const double recall = strict_hits == 0U ? 0.0 : static_cast<double>(tp) / static_cast<double>(strict_hits);
        const double precision = fast_hits == 0U ? 0.0 : static_cast<double>(tp) / static_cast<double>(fast_hits);
        const double expected_recall_floor = 1.0 - changed_fraction;
        if (recall + 0.01 < expected_recall_floor) avalanche_consistent = false;

        std::cout << "fault_ppm=" << ppm
                  << " changed_nonce_fraction=" << changed_fraction
                  << " fast_hits=" << fast_hits
                  << " true_positives=" << tp
                  << " false_negatives=" << fn
                  << " false_positives=" << fp
                  << " recall=" << recall
                  << " precision=" << precision << '\n';
    }

    std::cout << "strict_hit_recall_gate=0.995\n"
              << "avalanche_profile=" << (avalanche_consistent ? "CONSISTENT" : "CHECK") << '\n';
    return 0;
}
