#include "pepepow/core/header_builder.hpp"
#include "pepepow/crypto/pow.hpp"
#include "pepepow/cuda/header80_backend.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string_view>

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
    for (std::size_t index = 0; index < N; ++index) {
        output[index] = static_cast<std::uint8_t>(
            (hex_nibble(text[index * 2U]) << 4U) | hex_nibble(text[index * 2U + 1U]));
    }
    return output;
}

std::uint32_t load_le32(const std::uint8_t* value) noexcept {
    return static_cast<std::uint32_t>(value[0]) |
           (static_cast<std::uint32_t>(value[1]) << 8U) |
           (static_cast<std::uint32_t>(value[2]) << 16U) |
           (static_cast<std::uint32_t>(value[3]) << 24U);
}

std::uint32_t load_be32(const std::uint8_t* value) noexcept {
    return (static_cast<std::uint32_t>(value[0]) << 24U) |
           (static_cast<std::uint32_t>(value[1]) << 16U) |
           (static_cast<std::uint32_t>(value[2]) << 8U) |
           static_cast<std::uint32_t>(value[3]);
}

pepepow::MiningJob job_from_header(
    const pepepow::Header80& header,
    std::string_view job_id) {
    pepepow::MiningJob job;
    job.job_id = std::string(job_id);
    job.version = load_le32(header.data());
    std::copy_n(header.begin() + 4, 32, job.previous_hash.begin());
    std::copy_n(header.begin() + 36, 32, job.merkle_root.begin());
    job.ntime = load_le32(header.data() + 68);
    job.bits = load_le32(header.data() + 72);
    job.nonce = load_be32(header.data() + 76);
    return job;
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

struct ConsensusVector {
    std::string_view name;
    std::string_view header_hex;
    std::string_view expected_hash_hex;
};

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

        constexpr std::array<std::uint8_t, 32> maximum_target = [] {
            std::array<std::uint8_t, 32> value{};
            value.fill(0xffU);
            return value;
        }();

        constexpr std::array<std::uint32_t, 6> nonces{
            0U, 1U, 0x0000ffffU, 0x12345678U, 0x80000000U, 0xffffffffU};
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

        constexpr std::array<ConsensusVector, 5> consensus_vectors{{
            {
                "authoritative-known-chain",
                "0040002038e31388c54124146478ff691985eecd02610db91efbc9cd7aabca4900000000"
                "07647f0508057dbf8c99ddaa87543c04e31dfe3f383e7386903d50c91728fabe8"
                "30be16971e3021da96d9d33",
                "00000001fb895a82973fca52938848908d6a6cb3c0dfb93995dc61020ced0a6b"
            },
            {
                "live-associativity-5e095f",
                "004000206857ad8097ae27f653ff45b867b80e7de26d89f5ca91435a088a1f6200000000"
                "941cfbf2fc87b80ebc90c37b217ade46a9279726e6d0ea9cc1ff93d8d059fc8a"
                "013f676afb24011d005e095f",
                "7eca26c772b9ba046d0166ba569ef980ef9177b6a5c39a4aeac846bb6b5392cf"
            },
            {
                "live-associativity-647d3e",
                "004000206857ad8097ae27f653ff45b867b80e7de26d89f5ca91435a088a1f6200000000"
                "f258149f0751da0d9984edccec1173e197ccb16b7df02c1e0eeda0e500e877c3"
                "103f676afb24011d00647d3e",
                "acec2d397f400aa1e560840aae55d4bc32588e574af8b59822801bf2d988db3a"
            },
            {
                "live-associativity-a94244",
                "004000206857ad8097ae27f653ff45b867b80e7de26d89f5ca91435a088a1f6200000000"
                "4d24e268cabcd4367e7171f2619b7890062a23ac2640e53dacf74ca462e67e13"
                "1f3f676afb24011d00a94244",
                "57deedeec149db3d669273bfac6d2f9b075859ca53c1cccd69b435f94b0206d5"
            },
            {
                "live-accepted-064cd5",
                "004000206857ad8097ae27f653ff45b867b80e7de26d89f5ca91435a088a1f6200000000"
                "941cfbf2fc87b80ebc90c37b217ade46a9279726e6d0ea9cc1ff93d8d059fc8a"
                "013f676afb24011d00064cd5",
                "000000060dc7f9de9ff596f2c21fbfaf6dad29ab37fb52f6ff6fe105ff978213"
            }
        }};

        for (const auto& vector : consensus_vectors) {
            const auto header = parse_hex<80>(vector.header_hex);
            const auto expected = parse_hex<32>(vector.expected_hash_hex);
            auto job = job_from_header(header, vector.name);
            if (pepepow::build_header80(job) != header) {
                throw std::runtime_error("consensus Header80 reconstruction mismatch");
            }

            const auto cpu_hash = pepepow::crypto::calculate_header80_pow(header);
            if (cpu_hash != expected) {
                throw std::runtime_error("CPU consensus vector mismatch");
            }

            const auto gpu_candidate = backend.search(
                job,
                pepepow::SearchRange{job.nonce, 1U},
                maximum_target);
            if (!gpu_candidate.has_value() || gpu_candidate->nonce != job.nonce) {
                throw std::runtime_error("CUDA consensus vector returned no exact nonce");
            }
            if (gpu_candidate->hash != expected) {
                std::cout << "CONSENSUS_CUDA_FAIL name=" << vector.name << " expected=";
                print_hash(expected);
                std::cout << " actual=";
                print_hash(gpu_candidate->hash);
                std::cout << '\n';
                throw std::runtime_error("CUDA consensus vector mismatch");
            }
            std::cout << "consensus=" << vector.name << " hash=";
            print_hash(gpu_candidate->hash);
            std::cout << '\n';
        }

        std::cout << "PASS: 5 consensus HooHash vectors match on CPU/CUDA\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "FAIL: " << error.what() << '\n';
        return 1;
    }
}
