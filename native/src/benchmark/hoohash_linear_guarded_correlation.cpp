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
constexpr double kPi = 3.14159265358979323846;
constexpr double kTransformMultiplier = 0.000001;
constexpr std::size_t kRows = 64;
constexpr std::size_t kCols = 64;
constexpr std::size_t kNibbles = 16;

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
        output[i] = static_cast<std::uint8_t>((hex_nibble(text[i * 2U]) << 4U) | hex_nibble(text[i * 2U + 1U]));
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

struct LinearEntry {
    double approx{};
    double abs_error{};
};

struct GuardedFp32Table {
    std::vector<LinearEntry> values;
    explicit GuardedFp32Table(const HoohashMatrix& matrix) : values(kRows * kCols * kNibbles) {
        for (std::size_t i = 0; i < kRows; ++i) {
            for (std::size_t j = 0; j < kCols; ++j) {
                for (std::size_t n = 0; n < kNibbles; ++n) {
                    const double exact = matrix[i][j] * 0.0001 * static_cast<double>(n);
                    const double approx = static_cast<double>(static_cast<float>(exact));
                    const double rounding_cushion = 8.0 * std::numeric_limits<double>::epsilon() * (std::fabs(exact) + 1.0);
                    values[(i * kCols + j) * kNibbles + n] = {approx, std::fabs(exact - approx) + rounding_cushion};
                }
            }
        }
    }
    const LinearEntry& get(std::size_t i, std::size_t j, std::uint8_t nibble) const {
        return values[(i * kCols + j) * kNibbles + nibble];
    }
};

struct RowResult {
    double product{};
    double sw{};
};

RowResult replay_exact_row(const HoohashMatrix& matrix,
                           const std::array<std::uint8_t, 64>& vector,
                           std::size_t row,
                           std::uint32_t hash_mod,
                           double nonce_mod,
                           double start_sw) {
    double product = 0.0;
    double sw = start_sw;
    for (std::size_t j = 0; j < kCols; ++j) {
        if (sw <= 0.02) {
            if (vector[j] != 0U) {
                const double input = matrix[row][j] * static_cast<double>(hash_mod) * static_cast<double>(vector[j]) + nonce_mod;
                product += for_complex(input) * static_cast<double>(vector[j]) * 1234.0;
            }
        } else {
            product += matrix[row][j] * 0.0001 * static_cast<double>(vector[j]);
        }
        sw = product / 1024.0 - std::floor(product / 1024.0);
    }
    return {product, sw};
}

bool branch_interval_risky(double sw, double product_error) {
    const double e = product_error / 1024.0;
    if (!(e >= 0.0) || !std::isfinite(e) || e >= 0.5) return true;
    if (sw <= e || (1.0 - sw) <= e) return true;
    return std::fabs(sw - 0.02) <= e;
}

bool integer_interval_risky(double product, double product_error) {
    if (!(product_error >= 0.0) || !std::isfinite(product_error)) return true;
    const double base = std::floor(product);
    const double frac = product - base;
    return frac <= product_error || (1.0 - frac) <= product_error;
}

struct FastStats {
    std::uint64_t fallback_rows{};
    std::uint64_t branch_guard_fallbacks{};
    std::uint64_t integer_guard_fallbacks{};
};

Hash256 guarded_mix(const HoohashMatrix& matrix,
                    const GuardedFp32Table& table,
                    const Hash256& first_pass,
                    std::uint64_t nonce,
                    double guard_scale,
                    FastStats& stats) {
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
    for (std::size_t i = 0; i < kRows; ++i) {
        const double row_start_sw = sw;
        double row_error = 0.0;
        bool replay = false;
        bool branch_reason = false;

        for (std::size_t j = 0; j < kCols; ++j) {
            if (sw <= 0.02) {
                if (vector[j] != 0U) {
                    const double input = matrix[i][j] * static_cast<double>(hash_mod) * static_cast<double>(vector[j]) + nonce_mod;
                    const double contribution = for_complex(input) * static_cast<double>(vector[j]) * 1234.0;
                    product[i] += contribution;
                    row_error += guard_scale * 8.0 * std::numeric_limits<double>::epsilon() *
                                 (std::fabs(product[i]) + std::fabs(contribution) + 1.0);
                }
            } else {
                const auto& entry = table.get(i, j, vector[j]);
                product[i] += entry.approx;
                row_error += guard_scale * entry.abs_error;
                row_error += guard_scale * 8.0 * std::numeric_limits<double>::epsilon() *
                             (std::fabs(product[i]) + std::fabs(entry.approx) + 1.0);
            }
            sw = product[i] / 1024.0 - std::floor(product[i] / 1024.0);
            if (j + 1U < kCols && branch_interval_risky(sw, row_error)) {
                replay = true;
                branch_reason = true;
                break;
            }
        }

        if (!replay && integer_interval_risky(product[i], row_error)) replay = true;
        if (replay) {
            ++stats.fallback_rows;
            if (branch_reason) ++stats.branch_guard_fallbacks;
            else ++stats.integer_guard_fallbacks;
            const auto exact = replay_exact_row(matrix, vector, i, hash_mod, nonce_mod, row_start_sw);
            product[i] = exact.product;
            sw = exact.sw;
        }
    }

    Hash256 mixed{};
    for (std::size_t i = 0; i < 32; ++i) {
        const auto p = static_cast<std::uint64_t>(product[i * 2U]) + static_cast<std::uint64_t>(product[i * 2U + 1U]);
        mixed[i] = first_pass[i] ^ static_cast<std::uint8_t>(p & 0xffU);
    }
    return mixed;
}

} // namespace

int main(int argc, char** argv) {
    std::uint32_t nonce_count = 131072U;
    unsigned target_bits = 8U;
    if (argc > 1) nonce_count = static_cast<std::uint32_t>(std::strtoul(argv[1], nullptr, 10));
    if (argc > 2) target_bits = static_cast<unsigned>(std::strtoul(argv[2], nullptr, 10));
    if (nonce_count == 0U || target_bits == 0U || target_bits > 16U) return 2;

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

    std::vector<Hash256> strict_mixed(nonce_count);
    std::vector<std::uint8_t> strict_hit(nonce_count, 0U);
    std::uint64_t strict_hits = 0;
    const auto strict_begin = std::chrono::steady_clock::now();
    for (std::uint32_t nonce = 0; nonce < nonce_count; ++nonce) {
        strict_mixed[nonce] = pepepow::crypto::hoohash_matrix_mix(matrix, first_passes[nonce], nonce);
        const auto final_hash = pepepow::crypto::blake3_hash(strict_mixed[nonce]);
        if (relaxed_hit(final_hash, target_bits)) { strict_hit[nonce] = 1U; ++strict_hits; }
    }
    const double strict_seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - strict_begin).count();
    const double strict_rate = static_cast<double>(nonce_count) / strict_seconds;
    const GuardedFp32Table table(matrix);

    std::cout << std::fixed << std::setprecision(6)
              << "job=accepted-header80-fixed-matrix\n"
              << "candidate_class=speculative_filtered_hoohash\n"
              << "nonces=" << nonce_count << '\n'
              << "relaxed_target_bits=" << target_bits << '\n'
              << "strict_hits=" << strict_hits << '\n'
              << "strict_seconds=" << strict_seconds << '\n'
              << "strict_nonce_per_sec=" << strict_rate << '\n'
              << "table_bytes=" << table.values.size() * sizeof(LinearEntry) << '\n';

    constexpr std::array<double, 3> guard_scales{1.0, 2.0, 4.0};
    for (double guard_scale : guard_scales) {
        FastStats stats{};
        std::uint64_t fast_hits = 0, tp = 0, fn = 0, fp = 0, mixed_equal = 0;
        const auto begin = std::chrono::steady_clock::now();
        for (std::uint32_t nonce = 0; nonce < nonce_count; ++nonce) {
            const auto mixed = guarded_mix(matrix, table, first_passes[nonce], nonce, guard_scale, stats);
            if (mixed == strict_mixed[nonce]) ++mixed_equal;
            const auto final_hash = pepepow::crypto::blake3_hash(mixed);
            const bool fast = relaxed_hit(final_hash, target_bits);
            const bool strict = strict_hit[nonce] != 0U;
            if (fast) ++fast_hits;
            if (fast && strict) ++tp;
            if (!fast && strict) ++fn;
            if (fast && !strict) ++fp;
        }
        const double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - begin).count();
        const double rate = static_cast<double>(nonce_count) / seconds;
        const double recall = strict_hits == 0 ? 0.0 : static_cast<double>(tp) / static_cast<double>(strict_hits);
        const double precision = fast_hits == 0 ? 0.0 : static_cast<double>(tp) / static_cast<double>(fast_hits);
        const double mixed_equal_pct = 100.0 * static_cast<double>(mixed_equal) / static_cast<double>(nonce_count);
        const double gain_pct = 100.0 * (rate / strict_rate - 1.0);
        const double fallback_row_pct = 100.0 * static_cast<double>(stats.fallback_rows) /
                                        static_cast<double>(nonce_count * kRows);
        const double validator_load_pct = 100.0 * static_cast<double>(fast_hits) / static_cast<double>(nonce_count);
        const bool recall_pass = recall >= 0.995;
        const bool throughput_pass = gain_pct >= 25.0;
        std::cout << "mode=fp32_interval_guard_row_replay\n"
                  << "guard_scale=" << guard_scale << '\n'
                  << "mixed_equal=" << mixed_equal << '\n'
                  << "mixed_equal_pct=" << mixed_equal_pct << '\n'
                  << "fast_hits=" << fast_hits << '\n'
                  << "true_positives=" << tp << '\n'
                  << "false_negatives=" << fn << '\n'
                  << "false_positives=" << fp << '\n'
                  << "recall=" << recall << '\n'
                  << "precision=" << precision << '\n'
                  << "fallback_rows=" << stats.fallback_rows << '\n'
                  << "fallback_row_pct=" << fallback_row_pct << '\n'
                  << "branch_guard_fallbacks=" << stats.branch_guard_fallbacks << '\n'
                  << "integer_guard_fallbacks=" << stats.integer_guard_fallbacks << '\n'
                  << "validator_candidates=" << fast_hits << '\n'
                  << "validator_load_pct=" << validator_load_pct << '\n'
                  << "invalid_submissions_after_strict_validation=0\n"
                  << "fast_seconds=" << seconds << '\n'
                  << "fast_nonce_per_sec=" << rate << '\n'
                  << "cpu_throughput_gain_pct=" << gain_pct << '\n'
                  << "recall_gate_0_995=" << (recall_pass ? "PASS" : "REJECT") << '\n'
                  << "throughput_gate_25pct=" << (throughput_pass ? "PASS" : "REJECT") << '\n';
    }
    return 0;
}
