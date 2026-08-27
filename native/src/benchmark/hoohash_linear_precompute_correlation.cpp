#include "pepepow/crypto/blake3.hpp"
#include "pepepow/crypto/hoohash_reference.hpp"

#include <array>
#include <bit>
#include <chrono>
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
constexpr std::size_t kRows = 64;
constexpr std::size_t kCols = 64;
constexpr std::size_t kNibbles = 16;

enum class TableMode { ExactFp64, Mantissa48, Fp32 };

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

double quantize_mantissa48(double value) {
    auto bits = std::bit_cast<std::uint64_t>(value);
    bits &= ~std::uint64_t{0xFULL};
    return std::bit_cast<double>(bits);
}

const char* mode_name(TableMode mode) {
    switch (mode) {
        case TableMode::ExactFp64: return "exact_fp64_table";
        case TableMode::Mantissa48: return "mantissa48_table";
        case TableMode::Fp32: return "fp32_table";
    }
    return "unknown";
}

struct LinearTable {
    std::vector<double> values;
    explicit LinearTable(const HoohashMatrix& matrix, TableMode mode) : values(kRows * kCols * kNibbles) {
        for (std::size_t i = 0; i < kRows; ++i) {
            for (std::size_t j = 0; j < kCols; ++j) {
                for (std::size_t n = 0; n < kNibbles; ++n) {
                    double v = matrix[i][j] * 0.0001 * static_cast<double>(n);
                    if (mode == TableMode::Mantissa48) v = quantize_mantissa48(v);
                    if (mode == TableMode::Fp32) v = static_cast<double>(static_cast<float>(v));
                    values[(i * kCols + j) * kNibbles + n] = v;
                }
            }
        }
    }
    double get(std::size_t i, std::size_t j, std::uint8_t nibble) const {
        return values[(i * kCols + j) * kNibbles + nibble];
    }
};

Hash256 table_mix(const HoohashMatrix& matrix, const LinearTable& table, const Hash256& first_pass, std::uint64_t nonce) {
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
                    const double input = matrix[i][j] * static_cast<double>(hash_mod) * static_cast<double>(vector[j]) + nonce_mod;
                    product[i] += for_complex(input) * static_cast<double>(vector[j]) * 1234.0;
                }
            } else {
                product[i] += table.get(i, j, vector[j]);
            }
            sw = product[i] / 1024.0 - std::floor(product[i] / 1024.0);
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

    std::cout << std::fixed << std::setprecision(6)
              << "job=accepted-header80-fixed-matrix\n"
              << "nonces=" << nonce_count << '\n'
              << "relaxed_target_bits=" << target_bits << '\n'
              << "strict_hits=" << strict_hits << '\n'
              << "strict_seconds=" << strict_seconds << '\n'
              << "strict_nonce_per_sec=" << strict_rate << '\n';

    constexpr std::array<TableMode, 3> modes{TableMode::ExactFp64, TableMode::Mantissa48, TableMode::Fp32};
    for (TableMode mode : modes) {
        const LinearTable table(matrix, mode);
        std::uint64_t fast_hits = 0, tp = 0, fn = 0, fp = 0, mixed_equal = 0;
        const auto begin = std::chrono::steady_clock::now();
        for (std::uint32_t nonce = 0; nonce < nonce_count; ++nonce) {
            const auto mixed = table_mix(matrix, table, first_passes[nonce], nonce);
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
        const bool recall_pass = recall >= 0.995;
        std::cout << "mode=" << mode_name(mode) << '\n'
                  << "table_bytes=" << table.values.size() * sizeof(double) << '\n'
                  << "mixed_equal=" << mixed_equal << '\n'
                  << "mixed_equal_pct=" << mixed_equal_pct << '\n'
                  << "fast_hits=" << fast_hits << '\n'
                  << "true_positives=" << tp << '\n'
                  << "false_negatives=" << fn << '\n'
                  << "false_positives=" << fp << '\n'
                  << "recall=" << recall << '\n'
                  << "precision=" << precision << '\n'
                  << "fast_seconds=" << seconds << '\n'
                  << "fast_nonce_per_sec=" << rate << '\n'
                  << "cpu_throughput_gain_pct=" << gain_pct << '\n'
                  << "recall_gate_0_995=" << (recall_pass ? "PASS" : "REJECT") << '\n';
    }
    return 0;
}
