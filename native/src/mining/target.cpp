#include "pepepow/mining/target.hpp"

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <stdexcept>

namespace pepepow::mining {
namespace {

constexpr std::uint64_t kDifficultyScale = 1'000'000ULL;

// PEPEPOW/Foztor advertises Stratum difficulty in the historical HooHash
// wire scale. A wire value of 327.68 corresponds to effective difficulty
// 0.005. Keep this isolated on the KV6-C experimental branch until the live
// pool test confirms accepted shares with zero rejects.
constexpr long double kPepepowWireDifficultyScale = 65536.0L;

// Standard 0xffff difficulty-1 target used by PEPEPOW/HooHashV110.
// Big-endian: 00000000ffff0000... (not 0000ffff0000...).
constexpr std::array<std::uint8_t, 32> kDiff1Target{
    0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00};

// Multiplies a 256-bit big-endian value by a 32-bit scalar. The 320-bit
// result leaves enough headroom for the fixed difficulty scale.
std::array<std::uint8_t, 40> multiply_by_scale() noexcept {
    std::array<std::uint8_t, 40> output{};
    std::uint64_t carry = 0;

    for (std::size_t source = kDiff1Target.size(); source-- > 0;) {
        const std::uint64_t product =
            static_cast<std::uint64_t>(kDiff1Target[source]) * kDifficultyScale + carry;
        output[source + 8U] = static_cast<std::uint8_t>(product & 0xffU);
        carry = product >> 8U;
    }

    for (std::size_t index = 8U; index-- > 0;) {
        output[index] = static_cast<std::uint8_t>(carry & 0xffU);
        carry >>= 8U;
    }
    return output;
}

// Portable bitwise division of a 320-bit unsigned integer by uint64_t.
// It avoids compiler-specific 128-bit integer extensions and works on MSVC.
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

Target256 target_from_difficulty(double difficulty) {
    if (!std::isfinite(difficulty) || difficulty <= 0.0) {
        throw std::invalid_argument("difficulty must be finite and greater than zero");
    }

    const long double effective_difficulty =
        static_cast<long double>(difficulty) / kPepepowWireDifficultyScale;
    const long double scaled_value = effective_difficulty * kDifficultyScale;

    if (scaled_value > static_cast<long double>(std::numeric_limits<std::uint64_t>::max())) {
        throw std::overflow_error("difficulty is too large");
    }

    const auto scaled_difficulty = static_cast<std::uint64_t>(std::llround(scaled_value));
    if (scaled_difficulty == 0U) {
        throw std::invalid_argument("difficulty is below supported precision");
    }

    const auto wide_target = divide_u320_by_u64(multiply_by_scale(), scaled_difficulty);

    // Any nonzero high byte means the mathematical target is above uint256.
    // Stratum targets are saturated to the maximum representable value.
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
