#include "pepepow/crypto/blake3.hpp"
#include "pepepow/crypto/hoohash_reference.hpp"

#include <algorithm>
#include <array>
#include <bit>
#include <chrono>
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
    for (std::size_t i = 0; i < N; ++i) {
        output[i] = static_cast<std::uint8_t>((hex_nibble(text[i * 2U]) << 4U) |
                                              hex_nibble(text[i * 2U + 1U]));
    }
    return output;
}

void store_le32(std::uint8_t* out, std::uint32_t value) {
    out[0] = static_cast<std::uint8_t>(value);
    out[1] = static_cast<std::uint8_t>(value >> 8U);
    out[2] = static_cast<std::uint8_t>(value >> 16U);
    out[3] = static_cast<std::uint8_t>(value >> 24U);
}

bool relaxed_hit(const Hash256& hash, unsigned target_bits) {
    const unsigned full_bytes = target_bits / 8U;
    const unsigned rem_bits = target_bits % 8U;
    for (unsigned i = 0; i < full_bytes; ++i) if (hash[i] != 0U) return false;
    if (rem_bits == 0U) return true;
    const std::uint8_t mask = static_cast<std::uint8_t>(0xffU << (8U - rem_bits));
    return (hash[full_bytes] & mask) == 0U;
}

enum class ScoreMode { Prefix16, MinPair16, LeadingZeros, XorFold16 };

const char* mode_name(ScoreMode mode) {
    switch (mode) {
        case ScoreMode::Prefix16: return "firstpass_prefix16";
        case ScoreMode::MinPair16: return "firstpass_minpair16";
        case ScoreMode::LeadingZeros: return "firstpass_leading_zero_rank";
        case ScoreMode::XorFold16: return "firstpass_xorfold16";
    }
    return "unknown";
}

std::uint32_t score(const Hash256& hash, ScoreMode mode) {
    if (mode == ScoreMode::Prefix16) {
        return (static_cast<std::uint32_t>(hash[0]) << 8U) | hash[1];
    }
    if (mode == ScoreMode::MinPair16) {
        std::uint32_t best = 0xffffU;
        for (std::size_t i = 0; i < hash.size(); i += 2U) {
            const std::uint32_t value = (static_cast<std::uint32_t>(hash[i]) << 8U) | hash[i + 1U];
            best = std::min(best, value);
        }
        return best;
    }
    if (mode == ScoreMode::LeadingZeros) {
        unsigned zeros = 0U;
        for (std::uint8_t byte : hash) {
            if (byte == 0U) {
                zeros += 8U;
            } else {
                zeros += static_cast<unsigned>(std::countl_zero(static_cast<unsigned>(byte)) -
                                               (std::numeric_limits<unsigned>::digits - 8));
                break;
            }
        }
        return 256U - zeros;
    }
    std::uint32_t folded = 0U;
    for (std::size_t i = 0; i < hash.size(); i += 2U) {
        folded ^= (static_cast<std::uint32_t>(hash[i]) << 8U) | hash[i + 1U];
    }
    return folded & 0xffffU;
}

} // namespace

int main(int argc, char** argv) {
    std::uint32_t nonce_count = 131072U;
    unsigned target_bits = 8U;
    if (argc > 1) nonce_count = static_cast<std::uint32_t>(std::strtoul(argv[1], nullptr, 10));
    if (argc > 2) target_bits = static_cast<unsigned>(std::strtoul(argv[2], nullptr, 10));
    if (nonce_count == 0U || target_bits == 0U || target_bits > 12U) {
        std::cerr << "usage: hoohash_speculative_prefilter [nonces>0] [target_bits 1..12]\n";
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
    const HoohashMatrix matrix = pepepow::crypto::generate_hoohash_matrix(matrix_seed);

    std::vector<Hash256> first_passes(nonce_count);
    const auto pre_begin = std::chrono::steady_clock::now();
    for (std::uint32_t nonce = 0; nonce < nonce_count; ++nonce) {
        auto header = base_header;
        store_le32(header.data() + 76, nonce);
        first_passes[nonce] = pepepow::crypto::blake3_hash(header);
    }
    const auto pre_end = std::chrono::steady_clock::now();
    const double pre_seconds = std::chrono::duration<double>(pre_end - pre_begin).count();
    const double pre_rate = static_cast<double>(nonce_count) / pre_seconds;

    std::vector<std::uint8_t> strict_hit(nonce_count, 0U);
    std::uint64_t strict_hits = 0U;
    const auto strict_begin = std::chrono::steady_clock::now();
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
    const double strict_stage_rate = static_cast<double>(nonce_count) / strict_seconds;
    const double baseline_rate = static_cast<double>(nonce_count) / (pre_seconds + strict_seconds);

    std::cout << std::fixed << std::setprecision(6)
              << "job=accepted-header80-fixed-matrix\n"
              << "nonces=" << nonce_count << '\n'
              << "relaxed_target_bits=" << target_bits << '\n'
              << "strict_hits=" << strict_hits << '\n'
              << "firstpass_seconds=" << pre_seconds << '\n'
              << "firstpass_nonce_per_sec=" << pre_rate << '\n'
              << "strict_validator_seconds=" << strict_seconds << '\n'
              << "strict_validator_nonce_per_sec=" << strict_stage_rate << '\n'
              << "baseline_nonce_per_sec=" << baseline_rate << '\n';

    constexpr std::array<ScoreMode, 4> modes{ScoreMode::Prefix16, ScoreMode::MinPair16,
                                              ScoreMode::LeadingZeros, ScoreMode::XorFold16};
    constexpr std::array<double, 12> fractions{0.01, 0.02, 0.05, 0.10, 0.25, 0.50,
                                                0.75, 0.90, 0.95, 0.98, 0.995, 1.0};

    bool any_pass = false;
    for (ScoreMode mode : modes) {
        std::vector<std::pair<std::uint32_t, std::uint32_t>> ranked;
        ranked.reserve(nonce_count);
        for (std::uint32_t nonce = 0; nonce < nonce_count; ++nonce) {
            ranked.emplace_back(score(first_passes[nonce], mode), nonce);
        }
        std::sort(ranked.begin(), ranked.end(), [](const auto& a, const auto& b) {
            if (a.first != b.first) return a.first < b.first;
            return a.second < b.second;
        });

        std::vector<std::uint64_t> prefix_tp(nonce_count + 1U, 0U);
        for (std::size_t i = 0; i < ranked.size(); ++i) {
            prefix_tp[i + 1U] = prefix_tp[i] + (strict_hit[ranked[i].second] != 0U ? 1U : 0U);
        }

        double best_fraction = 1.0;
        double best_gain = -1.0;
        std::uint64_t best_fn = strict_hits;
        bool recall_pass = false;
        std::cout << "mode=" << mode_name(mode) << '\n';
        for (double fraction : fractions) {
            const std::size_t emitted = std::min<std::size_t>(nonce_count,
                static_cast<std::size_t>(std::ceil(fraction * static_cast<double>(nonce_count))));
            const std::uint64_t tp = prefix_tp[emitted];
            const std::uint64_t fn = strict_hits - tp;
            const std::uint64_t fp = static_cast<std::uint64_t>(emitted) - tp;
            const double recall = strict_hits == 0U ? 0.0 : static_cast<double>(tp) / strict_hits;
            const double precision = emitted == 0U ? 0.0 : static_cast<double>(tp) / emitted;
            const double validator_fraction = static_cast<double>(emitted) / nonce_count;
            const double effective_seconds_per_nonce = 1.0 / pre_rate + validator_fraction / strict_stage_rate;
            const double effective_rate = 1.0 / effective_seconds_per_nonce;
            const double gain = effective_rate / baseline_rate - 1.0;
            std::cout << "validator_fraction=" << validator_fraction
                      << " true_positives=" << tp
                      << " false_negatives=" << fn
                      << " false_positives=" << fp
                      << " recall=" << recall
                      << " precision=" << precision
                      << " effective_gain=" << gain << '\n';
            if (recall >= 0.995 && (!recall_pass || validator_fraction < best_fraction)) {
                recall_pass = true;
                best_fraction = validator_fraction;
                best_gain = gain;
                best_fn = fn;
            }
        }
        const bool pass = recall_pass && best_gain >= 0.25;
        any_pass = any_pass || pass;
        std::cout << "best_validator_fraction=" << best_fraction << '\n'
                  << "best_false_negatives=" << best_fn << '\n'
                  << "best_effective_gain=" << best_gain << '\n'
                  << "gate_recall_0_995_gain_0_25=" << (pass ? "PASS" : "REJECT") << '\n';
    }

    std::cout << "candidate_prefilter_gate=" << (any_pass ? "PASS" : "REJECT") << '\n'
              << "invalid_submissions=0\n";
    return 0;
}
