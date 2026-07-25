#include "pepepow/cuda/cuda_backend.hpp"
#include "pepepow/crypto/hoohash_reference.hpp"

#include <array>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <span>

int main(int argc, char** argv) {
    const std::size_t nonce_count = argc > 1
        ? static_cast<std::size_t>(std::strtoull(argv[1], nullptr, 10))
        : 32768U;
    const int device_index = argc > 2 ? std::atoi(argv[2]) : 0;
    const unsigned int threads_per_block = argc > 3
        ? static_cast<unsigned int>(std::strtoul(argv[3], nullptr, 10))
        : 128U;

    if (nonce_count == 0) {
        std::cerr << "nonce_count must be positive\n";
        return 2;
    }

    std::array<std::uint8_t, 32> previous_header{};
    for (std::size_t i = 0; i < previous_header.size(); ++i) {
        previous_header[i] = static_cast<std::uint8_t>(i);
    }

    constexpr std::uint64_t timestamp = 0x1122334455667788ULL;
    constexpr std::uint64_t first_nonce = 0xaabbccddeeff0010ULL;

    try {
        const auto matrix = pepepow::crypto::generate_hoohash_matrix(previous_header);
        const auto first_passes = pepepow::cuda_first_pass_hashes(
            device_index, previous_header, timestamp, first_nonce, nonce_count);
        const auto stats = pepepow::cuda_measure_warp_divergence(
            device_index,
            matrix,
            std::span<const std::uint8_t>(first_passes.data(), first_passes.size()),
            first_nonce,
            nonce_count,
            threads_per_block);

        const double divergent_percent = stats.warp_steps == 0
            ? 0.0
            : 100.0 * static_cast<double>(stats.divergent_steps) /
              static_cast<double>(stats.warp_steps);
        const double nonlinear_lane_percent = stats.active_lanes == 0
            ? 0.0
            : 100.0 * static_cast<double>(stats.nonlinear_lanes) /
              static_cast<double>(stats.active_lanes);
        const std::uint64_t nonlinear_calls =
            stats.exp_sincos_calls + stats.sin_squared_calls + stats.inverse_sqrt_calls;
        const double exp_sincos_percent = nonlinear_calls == 0
            ? 0.0
            : 100.0 * static_cast<double>(stats.exp_sincos_calls) /
              static_cast<double>(nonlinear_calls);
        const double sin_squared_percent = nonlinear_calls == 0
            ? 0.0
            : 100.0 * static_cast<double>(stats.sin_squared_calls) /
              static_cast<double>(nonlinear_calls);
        const double inverse_sqrt_percent = nonlinear_calls == 0
            ? 0.0
            : 100.0 * static_cast<double>(stats.inverse_sqrt_calls) /
              static_cast<double>(nonlinear_calls);
        const double retry_percent = nonlinear_calls == 0
            ? 0.0
            : 100.0 * static_cast<double>(stats.retry_calls) /
              static_cast<double>(nonlinear_calls);

        std::cout << "device=" << device_index << '\n';
        std::cout << "nonces=" << nonce_count << '\n';
        std::cout << "threads_per_block=" << threads_per_block << '\n';
        std::cout << "warp_steps=" << stats.warp_steps << '\n';
        std::cout << "uniform_nonlinear_steps=" << stats.uniform_nonlinear_steps << '\n';
        std::cout << "uniform_linear_steps=" << stats.uniform_linear_steps << '\n';
        std::cout << "divergent_steps=" << stats.divergent_steps << '\n';
        std::cout << "nonlinear_calls=" << nonlinear_calls << '\n';
        std::cout << "exp_sincos_calls=" << stats.exp_sincos_calls << '\n';
        std::cout << "sin_squared_calls=" << stats.sin_squared_calls << '\n';
        std::cout << "inverse_sqrt_calls=" << stats.inverse_sqrt_calls << '\n';
        std::cout << "invalid_results=" << stats.invalid_results << '\n';
        std::cout << "retry_calls=" << stats.retry_calls << '\n';
        std::cout << "zero_fallbacks=" << stats.zero_fallbacks << '\n';
        std::cout << std::fixed << std::setprecision(4);
        std::cout << "divergent_percent=" << divergent_percent << '\n';
        std::cout << "nonlinear_lane_percent=" << nonlinear_lane_percent << '\n';
        std::cout << "exp_sincos_percent=" << exp_sincos_percent << '\n';
        std::cout << "sin_squared_percent=" << sin_squared_percent << '\n';
        std::cout << "inverse_sqrt_percent=" << inverse_sqrt_percent << '\n';
        std::cout << "retry_percent=" << retry_percent << '\n';
    } catch (const std::exception& error) {
        std::cerr << "warp probe failed: " << error.what() << '\n';
        return 1;
    }

    return 0;
}
