#include "pepepow/core/header_builder.hpp"
#include "pepepow/crypto/pow.hpp"
#include "pepepow/cuda/header80_backend.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

pepepow::MiningJob make_benchmark_job() {
    pepepow::MiningJob job;
    job.job_id = "v110-v100-cohort";
    job.version = 0x20000000U;
    job.ntime = 0x65f2a880U;
    job.bits = 0x1d00ffffU;
    for (std::size_t i = 0; i < job.previous_hash.size(); ++i) {
        job.previous_hash[i] = static_cast<std::uint8_t>((i * 13U + 7U) & 0xffU);
        job.merkle_root[i] = static_cast<std::uint8_t>((i * 29U + 3U) & 0xffU);
    }
    return job;
}

unsigned int parse_u32(const char* text, const char* name) {
    if (text == nullptr || *text == '\0') {
        throw std::invalid_argument(std::string(name) + " is empty");
    }
    const unsigned long value = std::stoul(text);
    if (value > 0xffffffffUL) {
        throw std::invalid_argument(std::string(name) + " is too large");
    }
    return static_cast<unsigned int>(value);
}

std::uint64_t parse_u64(const char* text, const char* name) {
    if (text == nullptr || *text == '\0') {
        throw std::invalid_argument(std::string(name) + " is empty");
    }
    return std::stoull(text);
}

std::array<std::uint32_t, 64> validation_nonces() {
    std::array<std::uint32_t, 64> values{};
    values[0] = 0U;
    values[1] = 1U;
    values[2] = 0x0000ffffU;
    values[3] = 0x12345678U;
    values[4] = 0x80000000U;
    values[5] = 0xffffffffU;
    for (std::size_t i = 6; i < values.size(); ++i) {
        const auto n = static_cast<std::uint32_t>(i);
        values[i] = static_cast<std::uint32_t>(
            0x6a09e667U ^ (n * 0x9e3779b9U) ^ (n << 19U) ^ (n >> 5U));
    }
    return values;
}

void set_env_u32(const char* name, unsigned int value) {
    const std::string text = std::to_string(value);
    if (::setenv(name, text.c_str(), 1) != 0) {
        throw std::runtime_error(std::string("setenv failed for ") + name);
    }
}

} // namespace

int main(int argc, char** argv) {
    try {
        std::string engine = "cohort";
        unsigned int threads = 256U;
        unsigned int threshold = 16U;
        unsigned int blocks_per_sm = 10U;
        std::uint64_t count = 1228800ULL;
        unsigned int rounds = 3U;

        for (int i = 1; i < argc; ++i) {
            const std::string arg = argv[i];
            if (arg == "--engine" && i + 1 < argc) engine = argv[++i];
            else if (arg == "--threads" && i + 1 < argc) threads = parse_u32(argv[++i], "threads");
            else if (arg == "--threshold" && i + 1 < argc) threshold = parse_u32(argv[++i], "threshold");
            else if (arg == "--blocks-per-sm" && i + 1 < argc) blocks_per_sm = parse_u32(argv[++i], "blocks-per-sm");
            else if (arg == "--count" && i + 1 < argc) count = parse_u64(argv[++i], "count");
            else if (arg == "--rounds" && i + 1 < argc) rounds = parse_u32(argv[++i], "rounds");
            else if (arg == "--help") {
                std::cout
                    << "Usage: pepepow-v110-autotune --engine exact|cohort --threads N "
                    << "[--threshold 1..32] [--blocks-per-sm N] [--count N] [--rounds N]\n";
                return 0;
            } else {
                throw std::invalid_argument("unknown or incomplete argument: " + arg);
            }
        }

        if (engine != "exact" && engine != "cohort") {
            throw std::invalid_argument("engine must be exact or cohort");
        }
        if (threads < 96U || threads > 768U || (threads % 32U) != 0U) {
            throw std::invalid_argument("threads must be a multiple of 32 in [96,768]");
        }
        if (engine == "cohort" && threads > 256U) {
            throw std::invalid_argument("cohort engine supports at most 256 threads/block");
        }
        if (threshold < 1U || threshold > 32U) {
            throw std::invalid_argument("threshold must be in [1,32]");
        }
        if (blocks_per_sm < 1U || blocks_per_sm > 32U) {
            throw std::invalid_argument("blocks-per-sm must be in [1,32]");
        }
        if (count == 0U || count > 0x10000000ULL) {
            throw std::invalid_argument("count out of range");
        }
        if (rounds == 0U || rounds > 10U) {
            throw std::invalid_argument("rounds out of range");
        }

        if (::setenv("PEPEPOW_V110_ENGINE", engine.c_str(), 1) != 0) {
            throw std::runtime_error("setenv failed for PEPEPOW_V110_ENGINE");
        }
        set_env_u32("PEPEPOW_V110_COHORT_THRESHOLD", threshold);
        set_env_u32("PEPEPOW_V110_BLOCKS_PER_SM", blocks_per_sm);

        pepepow::Header80CudaBackend backend(0, threads);
        const auto devices = backend.enumerate_devices();
        if (devices.empty()) throw std::runtime_error("no CUDA device detected");
        const auto& device = devices.front();
        if (device.compute_major != 7 || device.compute_minor != 0) {
            throw std::runtime_error("v1.1.0 V100 autotune requires Volta sm_70");
        }

        auto job = make_benchmark_job();
        std::array<std::uint8_t, 32> maximum_target{};
        maximum_target.fill(0xffU);
        const auto nonces = validation_nonces();

        for (const auto nonce : nonces) {
            job.nonce = nonce;
            const auto header = pepepow::build_header80(job);
            const auto cpu_hash = pepepow::crypto::calculate_header80_pow(header);
            const auto gpu = backend.search(job, pepepow::SearchRange{nonce, 1U}, maximum_target);
            if (!gpu.has_value() || gpu->nonce != nonce || gpu->hash != cpu_hash) {
                std::cout << "AUTOTUNE_RESULT engine=" << engine
                          << " threads=" << threads
                          << " threshold=" << threshold
                          << " blocks_per_sm=" << blocks_per_sm
                          << " valid=0 hps=0 validation_samples=" << nonces.size()
                          << " reason=consensus_mismatch nonce=" << nonce << '\n';
                return 3;
            }
        }

        std::array<std::uint8_t, 32> impossible_target{};
        job.nonce = 0U;
        const std::uint64_t warmup_count = std::min<std::uint64_t>(count, 262144ULL);
        (void)backend.search(job, pepepow::SearchRange{0x01000000ULL, warmup_count}, impossible_target);

        std::vector<double> samples;
        samples.reserve(rounds);
        for (unsigned int round = 0; round < rounds; ++round) {
            const std::uint64_t begin = 0x02000000ULL + static_cast<std::uint64_t>(round) * count;
            const auto start = std::chrono::steady_clock::now();
            (void)backend.search(job, pepepow::SearchRange{begin, count}, impossible_target);
            const auto stop = std::chrono::steady_clock::now();
            const double seconds = std::chrono::duration<double>(stop - start).count();
            if (!(seconds > 0.0)) throw std::runtime_error("invalid benchmark duration");
            samples.push_back(static_cast<double>(count) / seconds);
        }

        std::sort(samples.begin(), samples.end());
        const double median = samples[samples.size() / 2U];
        double total = 0.0;
        for (const double value : samples) total += value;
        const double mean = total / static_cast<double>(samples.size());

        std::cout << std::fixed << std::setprecision(0)
                  << "AUTOTUNE_RESULT engine=" << engine
                  << " threads=" << threads
                  << " threshold=" << threshold
                  << " blocks_per_sm=" << blocks_per_sm
                  << " valid=1 validation_samples=" << nonces.size()
                  << " hps=" << median
                  << " mean_hps=" << mean
                  << " mhs=" << std::setprecision(3) << median / 1000000.0
                  << " device=\"" << device.name << "\"\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "AUTOTUNE_ERROR " << error.what() << '\n';
        return 2;
    }
}
