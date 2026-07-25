#include "pepepow/crypto/blake3.hpp"
#include "pepepow/crypto/pow.hpp"
#include "pepepow/cuda/cuda_backend.hpp"

#include <array>
#include <cassert>
#include <cstddef>
#include <cstdint>
#include <span>

int main() {
    std::array<std::uint8_t, 32> previous_header{};
    for (std::size_t i = 0; i < previous_header.size(); ++i) {
        previous_header[i] = static_cast<std::uint8_t>(i);
    }

    constexpr std::uint64_t timestamp = 0x1122334455667788ULL;
    constexpr std::uint64_t first_nonce = 0xaabbccddeeff0010ULL;
    constexpr std::size_t count = 3;

    const auto inputs = pepepow::cuda_build_pow_inputs(
        0, previous_header, timestamp, first_nonce, count);
    assert(inputs.size() == count * 80);

    for (std::size_t item = 0; item < count; ++item) {
        const auto* input = inputs.data() + item * 80;
        for (std::size_t i = 0; i < 32; ++i) assert(input[i] == previous_header[i]);
        assert(input[32] == 0x88U);
        assert(input[39] == 0x11U);
        for (std::size_t i = 40; i < 72; ++i) assert(input[i] == 0U);

        const std::uint64_t nonce = first_nonce + item;
        for (std::size_t i = 0; i < 8; ++i) {
            assert(input[72 + i] == static_cast<std::uint8_t>(nonce >> (i * 8U)));
        }
    }

    const auto gpu_first_passes = pepepow::cuda_first_pass_hashes(
        0, previous_header, timestamp, first_nonce, count);
    assert(gpu_first_passes.size() == count * 32);

    for (std::size_t item = 0; item < count; ++item) {
        const auto cpu_hash = pepepow::crypto::blake3_hash(
            std::span<const std::uint8_t>(inputs.data() + item * 80, 80));
        for (std::size_t i = 0; i < cpu_hash.size(); ++i) {
            assert(gpu_first_passes[item * 32 + i] == cpu_hash[i]);
        }
    }

    const auto matrix = pepepow::crypto::generate_hoohash_matrix(previous_header);
    const auto gpu_mixed = pepepow::cuda_hoohash_matrix_mixes(
        0, matrix, gpu_first_passes, first_nonce, count);
    assert(gpu_mixed.size() == count * 32);

    for (std::size_t item = 0; item < count; ++item) {
        pepepow::crypto::Hash256 first_pass{};
        for (std::size_t i = 0; i < 32; ++i) {
            first_pass[i] = gpu_first_passes[item * 32 + i];
        }
        const auto cpu_mixed = pepepow::crypto::hoohash_matrix_mix(
            matrix, first_pass, first_nonce + item);
        for (std::size_t i = 0; i < 32; ++i) {
            assert(gpu_mixed[item * 32 + i] == cpu_mixed[i]);
        }
    }

    const auto gpu_pow = pepepow::cuda_pow_hashes(
        0, matrix, previous_header, timestamp, first_nonce, count);
    assert(gpu_pow.size() == count * 32);

    for (std::size_t item = 0; item < count; ++item) {
        const pepepow::crypto::PowInput input{
            previous_header, timestamp, first_nonce + item};
        const auto cpu_pow = pepepow::crypto::calculate_pow(input);
        for (std::size_t i = 0; i < cpu_pow.size(); ++i) {
            assert(gpu_pow[item * 32 + i] == cpu_pow[i]);
        }
    }

    return 0;
}
