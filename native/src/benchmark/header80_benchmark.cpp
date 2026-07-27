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
    std::uint64_t count = 1048576ULL;
    if (argc > 1) count = std::strtoull(argv[1], nullptr, 10);
    if (count == 0 || count > 0x100000000ULL) {
        std::cerr << "invalid nonce count\n";
        return 2;
    }

    pepepow::MiningJob job;
    job.job_id = "header80-performance-benchmark";
    job.version = 0x20004000U;
    job.ntime = 0x6a673f01U;
    job.bits = 0x1d0124fbU;
    for (std::size_t i = 0; i < 32; ++i) {
        job.previous_hash[i] = static_cast<std::uint8_t>((i * 17U + 11U) & 0xffU);
        job.merkle_root[i] = static_cast<std::uint8_t>((i * 31U + 5U) & 0xffU);
    }

    std::array<std::uint8_t, 32> impossible_target{};

    try {
        pepepow::Header80CudaBackend backend(0);
        const auto devices = backend.enumerate_devices();
        if (devices.empty()) throw std::runtime_error("no CUDA device detected");

        // Warm up the CUDA context, matrix upload and persistent result buffer.
        (void)backend.search(job, pepepow::SearchRange{0, 65536}, impossible_target);

        const auto start = std::chrono::steady_clock::now();
        const auto candidate = backend.search(
            job, pepepow::SearchRange{65536, count}, impossible_target);
        const auto stop = std::chrono::steady_clock::now();
        if (candidate.has_value()) {
            throw std::runtime_error("zero target unexpectedly returned a candidate");
        }

        const double seconds = std::chrono::duration<double>(stop - start).count();
        const double hps = static_cast<double>(count) / seconds;
        std::cout << "PERFORMANCE_BENCHMARK device=\"" << devices.front().name << "\""
                  << " nonces=" << count
                  << " seconds=" << std::fixed << std::setprecision(4) << seconds
                  << " hps=" << std::setprecision(0) << hps
                  << " khs=" << std::setprecision(2) << hps / 1000.0
                  << " mhs=" << std::setprecision(3) << hps / 1000000.0
                  << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "PERFORMANCE_BENCHMARK_FAIL " << error.what() << '\n';
        return 1;
    }
}
