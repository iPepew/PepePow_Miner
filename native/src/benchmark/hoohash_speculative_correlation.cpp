#include "pepepow/crypto/blake3.hpp"
#include "pepepow/crypto/hoohash_reference.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <limits>
#include <stdexcept>
#include <string_view>
#include <vector>

namespace {

using pepepow::crypto::Hash256;
using pepepow::crypto::HoohashMatrix;

constexpr double kTransformMultiplier = 0.000001;

enum class FastMode { LinearizeNonlinear, ZeroNonlinear, BranchConstant };

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
    for (unsigned i = 0; i < full_bytes; ++i) if (hash[i] != 0U) return false;
    if (rem_bits == 0U) return true;
    const std::uint8_t mask = static_cast<std::uint8_t>(0xffU << (8U - rem_bits));
    return (hash[full_bytes] & mask) == 0U;
}

double cheap_nonlinear(double x, FastMode mode) {
    if (mode == FastMode::ZeroNonlinear) return 0.0;
    if (mode == FastMode::LinearizeNonlinear) return x * 0.0001 / 1234.0;
    const double one = x * kTransformMultiplier / 8.0 - std::floor(x * kTransformMultiplier / 8.0);
    if (one < 0.33) return 1.0;
    if (one < 0.66) return 0.5;
    return 0.0;
}

Hash256 fast_matrix_mix(const HoohashMatrix& matrix, const Hash256& first_pass,
                        std::uint64_t nonce, FastMode mode) {
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
            if (sw <= 0.02) {
                if (vector[j] != 0U) {
                    const double input = matrix[i][j] * static_cast<double>(hash_mod) *
                                         static_cast<double>(vector[j]) + nonce_mod;
                    if (mode == FastMode::LinearizeNonlinear) {
                        product[i] += matrix[i][j] * 0.0001 * static_cast<double>(vector[j]);
                    } else {
                        product[i] += cheap_nonlinear(input, mode) * static_cast<double>(vector[j]) * 1234.0;
                    }
                }
            } else {
                product[i] += matrix[i][j] * 0.0001 * static_cast<double>(vector[j]);
            }
            sw = product[i] / 1024.0 - std::floor(product[i] / 1024.0);
        }
    }

    Hash256 mixed{};
    for (std::size_t i = 0; i < 32; ++i) {
        const auto p = static_cast<std::uint64_t>(product[i * 2U]) +
                       static_cast<std::uint64_t>(product[i * 2U + 1U]);
        mixed[i] = first_pass[i] ^ static_cast<std::uint8_t>(p & 0xffU);
    }
    return mixed;
}

const char* mode_name(FastMode mode) {
    switch (mode) {
        case FastMode::LinearizeNonlinear: return "linearize_nonlinear";
        case FastMode::ZeroNonlinear: return "zero_nonlinear";
        case FastMode::BranchConstant: return "branch_constant";
    }
    return "unknown";
}

} // namespace

int main(int argc, char** argv) {
    std::uint32_t nonce_count = 16384U;
    unsigned target_bits = 6U;
    if (argc > 1) nonce_count = static_cast<std::uint32_t>(std::strtoul(argv[1], nullptr, 10));
    if (argc > 2) target_bits = static_cast<unsigned>(std::strtoul(argv[2], nullptr, 10));
    if (nonce_count == 0U || target_bits == 0U || target_bits > 8U) {
        std::cerr << "usage: hoohash_speculative_correlation [nonces>0] [target_bits 1..8]\n";
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

    std::vector<Hash256> first_passes(nonce_count);
    for (std::uint32_t nonce = 0; nonce < nonce_count; ++nonce) {
        auto header = base_header;
        store_le32(header.data() + 76, nonce);
        first_passes[nonce] = pepepow::crypto::blake3_hash(header);
    }

    std::vector<std::uint8_t> strict_hit(nonce_count, 0U);
    const auto strict_begin = std::chrono::steady_clock::now();
    std::uint64_t strict_hits = 0U;
    for (std::uint32_t nonce = 0; nonce < nonce_count; ++nonce) {
        const auto mixed = pepepow::crypto::hoohash_matrix_mix(matrix, first_passes[nonce], nonce);
        const auto final_hash = pepepow::crypto::blake3_hash(mixed);
        if (relaxed_hit(final_hash, target_bits)) {
            strict_hit[nonce] = 1U;
            ++strict_hits;
        }
    }
    const auto strict_end = std::chrono::steady_clock::now();
    const double strict_seconds = std::chrono::duration<double>(strict_end - strict_begin).count();
    const double strict_rate = static_cast<double>(nonce_count) / strict_seconds;

    std::cout << std::fixed << std::setprecision(6)
              << "job=accepted-header80-fixed-matrix\n"
              << "nonces=" << nonce_count << '\n'
              << "relaxed_target_bits=" << target_bits << '\n'
              << "strict_hits=" << strict_hits << '\n'
              << "strict_seconds=" << strict_seconds << '\n'
              << "strict_nonce_per_sec=" << strict_rate << '\n';

    constexpr std::array<FastMode, 3> modes{FastMode::LinearizeNonlinear,
                                            FastMode::ZeroNonlinear,
                                            FastMode::BranchConstant};
    constexpr std::array<unsigned, 14> cutoffs{4U, 8U, 16U, 32U, 64U, 128U, 192U,
                                               224U, 240U, 248U, 252U, 254U, 255U, 256U};

    bool any_direct_recall_pass = false;
    bool any_effective_pass = false;
    for (FastMode mode : modes) {
        std::vector<std::uint8_t> fast_prefix(nonce_count, 0U);
        std::uint64_t fast_hits = 0U;
        std::uint64_t true_positives = 0U;
        std::uint64_t false_negatives = 0U;
        std::uint64_t false_positives = 0U;

        const auto begin = std::chrono::steady_clock::now();
        for (std::uint32_t nonce = 0; nonce < nonce_count; ++nonce) {
            const auto mixed = fast_matrix_mix(matrix, first_passes[nonce], nonce, mode);
            const auto final_hash = pepepow::crypto::blake3_hash(mixed);
            fast_prefix[nonce] = final_hash[0];
            const bool fast = relaxed_hit(final_hash, target_bits);
            const bool strict = strict_hit[nonce] != 0U;
            if (fast) ++fast_hits;
            if (fast && strict) ++true_positives;
            if (!fast && strict) ++false_negatives;
            if (fast && !strict) ++false_positives;
        }
        const auto end = std::chrono::steady_clock::now();
        const double fast_seconds = std::chrono::duration<double>(end - begin).count();
        const double fast_rate = static_cast<double>(nonce_count) / fast_seconds;
        const double recall = strict_hits == 0U ? 0.0 :
            static_cast<double>(true_positives) / static_cast<double>(strict_hits);
        const double precision = fast_hits == 0U ? 0.0 :
            static_cast<double>(true_positives) / static_cast<double>(fast_hits);
        const double throughput_gain = fast_rate / strict_rate - 1.0;
        const bool direct_recall_pass = recall >= 0.995;
        any_direct_recall_pass = any_direct_recall_pass || direct_recall_pass;

        std::cout << "mode=" << mode_name(mode) << '\n'
                  << "fast_hits=" << fast_hits << '\n'
                  << "true_positives=" << true_positives << '\n'
                  << "false_negatives=" << false_negatives << '\n'
                  << "false_positives=" << false_positives << '\n'
                  << "recall=" << recall << '\n'
                  << "precision=" << precision << '\n'
                  << "fast_seconds=" << fast_seconds << '\n'
                  << "fast_nonce_per_sec=" << fast_rate << '\n'
                  << "throughput_gain=" << throughput_gain << '\n'
                  << "recall_gate_0_995=" << (direct_recall_pass ? "PASS" : "REJECT") << '\n';

        double best_validator_fraction = std::numeric_limits<double>::infinity();
        double best_effective_gain = -1.0;
        unsigned best_cutoff = 0U;
        std::uint64_t best_fn = strict_hits;
        for (unsigned cutoff : cutoffs) {
            std::uint64_t emitted = 0U;
            std::uint64_t tp = 0U;
            for (std::uint32_t nonce = 0; nonce < nonce_count; ++nonce) {
                const bool emit = static_cast<unsigned>(fast_prefix[nonce]) < cutoff;
                if (emit) {
                    ++emitted;
                    if (strict_hit[nonce] != 0U) ++tp;
                }
            }
            const std::uint64_t fn = strict_hits - tp;
            const double sweep_recall = strict_hits == 0U ? 0.0 :
                static_cast<double>(tp) / static_cast<double>(strict_hits);
            const double validator_fraction = static_cast<double>(emitted) / static_cast<double>(nonce_count);
            const double effective_rate = 1.0 / (1.0 / fast_rate + validator_fraction / strict_rate);
            const double effective_gain = effective_rate / strict_rate - 1.0;
            std::cout << "superset_cutoff=" << cutoff
                      << " validator_fraction=" << validator_fraction
                      << " recall=" << sweep_recall
                      << " false_negatives=" << fn
                      << " effective_gain=" << effective_gain << '\n';
            if (sweep_recall >= 0.995 && validator_fraction < best_validator_fraction) {
                best_validator_fraction = validator_fraction;
                best_effective_gain = effective_gain;
                best_cutoff = cutoff;
                best_fn = fn;
            }
        }

        const bool superset_recall_pass = std::isfinite(best_validator_fraction);
        const bool effective_pass = superset_recall_pass && best_effective_gain >= 0.25;
        any_effective_pass = any_effective_pass || effective_pass;
        std::cout << "superset_best_cutoff=" << best_cutoff << '\n'
                  << "superset_best_validator_fraction="
                  << (superset_recall_pass ? best_validator_fraction : 1.0) << '\n'
                  << "superset_best_false_negatives=" << best_fn << '\n'
                  << "superset_best_effective_gain=" << best_effective_gain << '\n'
                  << "superset_gate_recall_0_995_gain_0_25=" << (effective_pass ? "PASS" : "REJECT") << '\n';
    }

    std::cout << "direct_correlation_gate=" << (any_direct_recall_pass ? "PASS" : "REJECT") << '\n'
              << "superset_effective_gate=" << (any_effective_pass ? "PASS" : "REJECT") << '\n';
    return 0;
}
