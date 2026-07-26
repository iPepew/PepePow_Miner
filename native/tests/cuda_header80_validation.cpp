#include "pepepow/core/header_builder.hpp"
#include "pepepow/crypto/pow.hpp"
#include "pepepow/cuda/header80_backend.hpp"

#include <array>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <stdexcept>

namespace {

void print_hash(const pepepow::Hash256& hash) {
    std::ios old_state(nullptr);
    old_state.copyfmt(std::cout);
    std::cout << std::hex << std::setfill('0');
    for (const auto byte : hash) {
        std::cout << std::setw(2) << static_cast<unsigned int>(byte);
    }
    std::cout.copyfmt(old_state);
}

pepepow::MiningJob make_validation_job() {
    pepepow::MiningJob job;
    job.job_id = "cuda-header80-validation";
    job.version = 0x20000000U;
    job.ntime = 0x65f2a880U;
    job.bits = 0x1d00ffffU;

    for (std::size_t i = 0; i < job.previous_hash.size(); ++i) {
        job.previous_hash[i] = static_cast<std::uint8_t>((i * 13U + 7U) & 0xffU);
        job.merkle_root[i] = static_cast<std::uint8_t>((i * 29U + 3U) & 0xffU);
    }
    return job;
}

} // namespace

int main() {
    try {
        pepepow::Header80CudaBackend backend(0);
        const auto devices = backend.enumerate_devices();
        if (devices.empty()) {
            throw std::runtime_error("no CUDA device detected");
        }

        const auto& device = devices.front();
        std::cout << "CUDA device: " << device.name
                  << " sm_" << device.compute_major << device.compute_minor << '\n';

        if (device.compute_major != 8 || device.compute_minor != 6) {
            std::cout << "Warning: release validation target is RTX 3080 / sm_86\n";
        }

        constexpr std::array<std::uint32_t, 6> nonces{
            0U, 1U, 0x0000ffffU, 0x12345678U, 0x80000000U, 0xffffffffU};
        constexpr std::array<std::uint8_t, 32> maximum_target = [] {
            std::array<std::uint8_t, 32> value{};
            value.fill(0xffU);
            return value;
        }();

        for (const auto nonce : nonces) {
            auto job = make_validation_job();
            job.nonce = nonce;
            const auto header = pepepow::build_header80(job);
            const auto cpu_hash = pepepow::crypto::calculate_header80_pow(header);

            const auto gpu_candidate = backend.search(
                job,
                pepepow::SearchRange{nonce, 1U},
                maximum_target);

            if (!gpu_candidate.has_value()) {
                throw std::runtime_error("CUDA backend returned no result for maximum target");
            }
            if (gpu_candidate->nonce != nonce) {
                throw std::runtime_error("CUDA backend returned an unexpected nonce");
            }

            std::cout << "nonce=0x" << std::hex << std::setw(8) << std::setfill('0')
                      << nonce << std::dec << " cpu=";
            print_hash(cpu_hash);
            std::cout << " gpu=";
            print_hash(gpu_candidate->hash);
            std::cout << '\n';

            if (gpu_candidate->hash != cpu_hash) {
                throw std::runtime_error("CPU/CUDA header80 hash mismatch");
            }
        }

        std::cout << "PASS: canonical header80 CPU/CUDA hashes match\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
