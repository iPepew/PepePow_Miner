#include "pepepow/core/header_builder.hpp"
#include "pepepow/crypto/pow.hpp"
#include "pepepow/cuda/header80_backend.hpp"

#include <array>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <stdexcept>

int main(int argc, char** argv) {
    std::uint64_t count = 100000ULL;
    if (argc > 1) count = std::strtoull(argv[1], nullptr, 10);
    if (count == 0 || count > 1000000ULL) {
        std::cerr << "invalid differential count\n";
        return 2;
    }

    pepepow::MiningJob job;
    job.job_id = "header80-production-differential";
    job.version = 0x20004000U;
    job.ntime = 0x6a673f01U;
    job.bits = 0x1d0124fbU;
    for (std::size_t i = 0; i < 32; ++i) {
        job.previous_hash[i] = static_cast<std::uint8_t>((i * 17U + 11U) & 0xffU);
        job.merkle_root[i] = static_cast<std::uint8_t>((i * 31U + 5U) & 0xffU);
    }

    constexpr std::array<std::uint8_t, 32> maximum_target = [] {
        std::array<std::uint8_t, 32> value{};
        value.fill(0xffU);
        return value;
    }();

    try {
        pepepow::Header80CudaBackend backend(0);
        const auto devices = backend.enumerate_devices();
        if (devices.empty()) throw std::runtime_error("no CUDA device detected");

        // Warm up context, matrix/LUT upload and persistent result storage.
        auto warmup_job = job;
        warmup_job.nonce = 0U;
        (void)backend.search(warmup_job, pepepow::SearchRange{0U, 1U}, maximum_target);

        std::uint64_t mismatches = 0;
        const auto start = std::chrono::steady_clock::now();
        for (std::uint64_t nonce64 = 0; nonce64 < count; ++nonce64) {
            const auto nonce = static_cast<std::uint32_t>(nonce64);
            job.nonce = nonce;
            const auto header = pepepow::build_header80(job);
            const auto expected = pepepow::crypto::calculate_header80_pow(header);
            const auto candidate = backend.search(
                job, pepepow::SearchRange{nonce, 1U}, maximum_target);
            if (!candidate.has_value() || candidate->nonce != nonce || candidate->hash != expected) {
                ++mismatches;
                if (mismatches <= 8U) {
                    std::cerr << "mismatch nonce=" << nonce64
                              << " candidate=" << (candidate.has_value() ? 1 : 0) << '\n';
                }
            }
        }
        const auto stop = std::chrono::steady_clock::now();
        const double seconds = std::chrono::duration<double>(stop - start).count();

        std::cout << "differential_cases=" << count << '\n'
                  << "differential_mismatches=" << mismatches << '\n'
                  << "differential_seconds=" << std::fixed << std::setprecision(6)
                  << seconds << '\n';
        return mismatches == 0 ? 0 : 3;
    } catch (const std::exception& error) {
        std::cerr << "DIFFERENTIAL_FAIL " << error.what() << '\n';
        return 1;
    }
}
