#include "pepepow/mining/target.hpp"

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <stdexcept>

namespace pepepow::mining {
namespace {

// Twelve decimal digits keep the target boundary effectively exact for live
// pool difficulties while still fitting the fixed-point denominator in u64.
// The denominator is rounded upward, making the resulting target conservative.
constexpr std::uint64_t kFixedPrecisionScale = 1'000'000'000'000ULL;

std::array<std::uint8_t, 40> multiply_by_fixed_precision(
    const Target256& base_target) noexcept {
    std::array<std::uint8_t, 40> output{};
    std::uint64_t carry = 0;
    for (std::size_t source = base_target.size(); source-- > 0;) {
        const std::uint64_t product =
            static_cast<std::uint64_t>(base_target[source]) * kFixedPrecisionScale + carry;
        output[source + 8U] = static_cast<std::uint8_t>(product & 0xffU);
        carry = product >> 8U;
    }
    for (std::size_t index = 8U; index-- > 0;) {
        output[index] = static_cast<std::uint8_t>(carry & 0xffU);
        carry >>= 8U;
    }
    return output;
}

std::array<std::uint8_t, 40> divide_u320_by_u64(
    const std::array<std::uint8_t, 40>& numerator,
    std::uint64_t denominator) {
    if (denominator == 0U) throw std::invalid_argument("zero target denominator");
    std::array<std::uint8_t, 40> quotient{};
    std::uint64_t remainder = 0;
    const std::uint64_t half = denominator >> 1U;
    const bool denominator_is_odd = (denominator & 1U) != 0U;
    for (std::size_t byte_index = 0; byte_index < numerator.size(); ++byte_index) {
        for (int bit_index = 7; bit_index >= 0; --bit_index) {
            const std::uint64_t bit =
                (static_cast<std::uint64_t>(numerator[byte_index]) >> bit_index) & 1U;
            const bool quotient_bit = remainder > half ||
                (remainder == half && (!denominator_is_odd || bit != 0U));
            if (quotient_bit) {
                remainder = remainder - (denominator - remainder - bit);
                quotient[byte_index] |= static_cast<std::uint8_t>(1U << bit_index);
            } else {
                remainder = remainder + remainder + bit;
            }
        }
    }
    return quotient;
}

} // namespace

Target256 target_from_compact(std::uint32_t compact_bits) {
    const std::uint32_t exponent = compact_bits >> 24U;
    const std::uint32_t mantissa = compact_bits & 0x007fffffU;
    const bool negative = (compact_bits & 0x00800000U) != 0U;

    if (negative || mantissa == 0U) {
        throw std::invalid_argument("compact target is negative or zero");
    }
    if (exponent > 32U) {
        throw std::overflow_error("compact target exceeds 256 bits");
    }

    Target256 output{};
    if (exponent <= 3U) {
        const std::uint32_t value = mantissa >> (8U * (3U - exponent));
        for (std::uint32_t byte = 0; byte < exponent; ++byte) {
            output[32U - exponent + byte] = static_cast<std::uint8_t>(
                value >> (8U * (exponent - 1U - byte)));
        }
        return output;
    }

    const std::size_t start = 32U - exponent;
    output[start] = static_cast<std::uint8_t>(mantissa >> 16U);
    output[start + 1U] = static_cast<std::uint8_t>(mantissa >> 8U);
    output[start + 2U] = static_cast<std::uint8_t>(mantissa);
    return output;
}

Target256 target_from_difficulty(
    double stratum_difficulty,
    std::uint32_t compact_bits) {
    if (!std::isfinite(stratum_difficulty) || stratum_difficulty <= 0.0) {
        throw std::invalid_argument("difficulty must be finite and greater than zero");
    }

    const Target256 network_target = target_from_compact(compact_bits);
    const long double normalized_difficulty =
        static_cast<long double>(stratum_difficulty) /
        static_cast<long double>(kStratumDifficultyWireScale);
    const long double scaled_value =
        normalized_difficulty * static_cast<long double>(kFixedPrecisionScale);

    if (scaled_value > static_cast<long double>(std::numeric_limits<std::uint64_t>::max())) {
        throw std::overflow_error("difficulty is too large");
    }

    // Ceil is intentional. A denominator rounded down would create a target
    // slightly above the pool boundary and produce sporadic low-difficulty
    // rejects exactly at the edge.
    const auto scaled_difficulty = static_cast<std::uint64_t>(std::ceil(scaled_value));
    if (scaled_difficulty == 0U) {
        throw std::invalid_argument("difficulty is below supported precision");
    }

    const auto wide_target = divide_u320_by_u64(
        multiply_by_fixed_precision(network_target), scaled_difficulty);

    for (std::size_t index = 0; index < 8U; ++index) {
        if (wide_target[index] != 0U) {
            Target256 maximum{};
            maximum.fill(0xffU);
            return maximum;
        }
    }

    Target256 output{};
    for (std::size_t index = 0; index < output.size(); ++index) {
        output[index] = wide_target[index + 8U];
    }
    return output;
}

bool hash_meets_target_be(const Hash256& hash, const Target256& target) noexcept {
    for (std::size_t index = 0; index < hash.size(); ++index) {
        if (hash[index] < target[index]) return true;
        if (hash[index] > target[index]) return false;
    }
    return true;
}

} // namespace pepepow::mining
