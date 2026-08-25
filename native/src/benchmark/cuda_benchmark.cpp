#include "pepepow/crypto/hoohash_reference.hpp"
#include "pepepow/crypto/pow.hpp"
#include "pepepow/cuda/cuda_backend.hpp"

#include <algorithm>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>

int main(int argc, char** argv) {
    std::size_t count = 1024;
    int device = 0;
    unsigned int threads = 64;
    std::size_t differential_count = 0;
    if (argc > 1) count = static_cast<std::size_t>(std::strtoull(argv[1], nullptr, 10));
    if (argc > 2) device = std::atoi(argv[2]);
    if (argc > 3) threads = static_cast<unsigned int>(std::strtoul(argv[3], nullptr, 10));
    if (argc > 4) differential_count = static_cast<std::size_t>(std::strtoull(argv[4], nullptr, 10));
    if (count == 0) {
        std::cerr << "nonce count must be greater than zero\n";
        return 2;
    }
    differential_count = std::min(differential_count, count);

    pepepow::crypto::Hash256 previous_header{};
    for (std::size_t i = 0; i < previous_header.size(); ++i) {
        previous_header[i] = static_cast<std::uint8_t>(i * 7U + 3U);
    }
    const auto matrix = pepepow::crypto::generate_hoohash_matrix(previous_header);

    constexpr std::uint64_t timestamp = 1725374568455ULL;
    constexpr std::uint64_t first_nonce = 0;

    try {
        const auto start = std::chrono::steady_clock::now();
        const auto hashes = pepepow::cuda_pow_hashes_tuned(
            device, matrix, previous_header, timestamp, first_nonce, count, threads);
        const auto stop = std::chrono::steady_clock::now();
        const double seconds = std::chrono::duration<double>(stop - start).count();
        const double hashes_per_second = static_cast<double>(count) / seconds;

        if (hashes.size() != count * 32U) {
            std::cerr << "unexpected CUDA output size: " << hashes.size() << '\n';
            return 4;
        }

        std::size_t mismatches = 0;
        const auto diff_start = std::chrono::steady_clock::now();
        for (std::size_t i = 0; i < differential_count; ++i) {
            pepepow::crypto::PowInput input{};
            input.previous_header = previous_header;
            input.timestamp = static_cast<std::int64_t>(timestamp);
            input.nonce = first_nonce + static_cast<std::uint64_t>(i);
            const auto expected = pepepow::crypto::calculate_pow(input);
            const auto* actual = hashes.data() + i * 32U;
            if (!std::equal(expected.begin(), expected.end(), actual)) {
                ++mismatches;
            }
        }
        const auto diff_stop = std::chrono::steady_clock::now();
        const double differential_seconds =
            std::chrono::duration<double>(diff_stop - diff_start).count();

        std::cout << "device=" << device << '\n'
                  << "threads_per_block=" << threads << '\n'
                  << "nonces=" << count << '\n'
                  << "seconds=" << std::fixed << std::setprecision(6) << seconds << '\n'
                  << "hashes_per_second=" << std::fixed << std::setprecision(2)
                  << hashes_per_second << '\n'
                  << "output_bytes=" << hashes.size() << '\n'
                  << "differential_cases=" << differential_count << '\n'
                  << "differential_mismatches=" << mismatches << '\n'
                  << "differential_seconds=" << std::fixed << std::setprecision(6)
                  << differential_seconds << '\n';

        if (mismatches != 0) {
            return 3;
        }
    } catch (const std::exception& error) {
        std::cerr << "benchmark failed: " << error.what() << '\n';
        return 1;
    }

    return 0;
}
