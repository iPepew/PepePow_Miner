#include "pepepow/mining/target.hpp"

#include <boost/multiprecision/cpp_int.hpp>

#include <cmath>
#include <limits>
#include <stdexcept>

namespace pepepow::mining {
namespace {

using boost::multiprecision::cpp_int;

const cpp_int& diff1_target() {
    static const cpp_int value("0x0000ffff00000000000000000000000000000000000000000000000000000000");
    return value;
}

const cpp_int& max_target() {
    static const cpp_int value = (cpp_int(1) << 256U) - 1;
    return value;
}

} // namespace

Target256 target_from_difficulty(double difficulty) {
    if (!std::isfinite(difficulty) || difficulty <= 0.0) {
        throw std::invalid_argument("difficulty must be finite and greater than zero");
    }

    // Preserve fractional vardiff values without converting the 256-bit target
    // through floating point. Six decimal places are sufficient for the pool's
    // advertised minimum wire difficulty and avoid platform-dependent rounding.
    constexpr std::uint64_t scale = 1'000'000ULL;
    const long double scaled_value = static_cast<long double>(difficulty) * scale;
    if (scaled_value > static_cast<long double>(std::numeric_limits<std::uint64_t>::max())) {
        throw std::overflow_error("difficulty is too large");
    }

    const auto scaled_difficulty = static_cast<std::uint64_t>(std::llround(scaled_value));
    if (scaled_difficulty == 0) {
        throw std::invalid_argument("difficulty is below supported precision");
    }

    cpp_int target = (diff1_target() * scale) / scaled_difficulty;
    if (target > max_target()) target = max_target();

    Target256 output{};
    for (std::size_t index = 0; index < output.size(); ++index) {
        const std::size_t shift = (output.size() - 1U - index) * 8U;
        const cpp_int byte = (target >> shift) & 0xff;
        output[index] = static_cast<std::uint8_t>(byte.convert_to<unsigned int>());
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

} // namespace pepepow::mining {
