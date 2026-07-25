#include "pepepow/core/header_builder.hpp"
#include "pepepow/crypto/blake3.hpp"
#include "pepepow/crypto/hoohash_reference.hpp"
#include "pepepow/crypto/pow.hpp"

#include <array>
#include <cassert>
#include <cmath>
#include <cstddef>
#include <cstdint>

int main() {
    pepepow::MiningJob job{};
    job.version = 0x11223344U;
    job.ntime = 0x55667788U;
    job.bits = 0x99aabbccU;
    job.nonce = 0xddeeff00U;

    for (std::size_t i = 0; i < job.previous_hash.size(); ++i) {
        job.previous_hash[i] = static_cast<std::uint8_t>(i);
        job.merkle_root[i] = static_cast<std::uint8_t>(0xffU - i);
    }

    const auto header = pepepow::build_header80(job);
    assert(header[0] == 0x44U);
    assert(header[79] == 0xddU);

    pepepow::crypto::Hash256 seed{};
    for (std::size_t i = 0; i < seed.size(); ++i) seed[i] = static_cast<std::uint8_t>(i);

    auto rng = pepepow::crypto::make_xoshiro(seed);
    assert(rng.next() == 0x171513110f151311ULL);
    assert(rng.next() == 0xa2209f1d9c1e9d1bULL);
    assert(rng.next() == 0xe0d100f0a090c0b0ULL);
    assert(rng.next() == 0xf4601386bb253984ULL);

    const auto matrix = pepepow::crypto::generate_hoohash_matrix(seed);
    assert(std::fabs(matrix[0][0] - 58915.321030401465) < 1e-9);
    assert(std::fabs(matrix[0][1] - 609842.1280295221) < 1e-9);

    constexpr std::array<std::uint8_t, 3> abc{'a', 'b', 'c'};
    const auto abc_hash = pepepow::crypto::blake3_hash(abc);
    constexpr pepepow::crypto::Hash256 expected_abc{
        0x64,0x37,0xb3,0xac,0x38,0x46,0x51,0x33,0xff,0xb6,0x3b,0x75,0x27,0x3a,0x8d,0xb5,
        0x48,0xc5,0x58,0x46,0x5d,0x79,0xdb,0x03,0xfd,0x35,0x9c,0x6c,0xd5,0xbd,0x9d,0x85};
    assert(abc_hash == expected_abc);

    pepepow::crypto::PowInput input{};
    input.previous_header = {0xa4,0x9d,0xbc,0x7d,0x44,0xae,0x83,0x25,0x38,0x23,0x59,0x2f,0xd3,0x88,0xf2,0x19,
                             0xf3,0xcb,0x83,0x63,0x9d,0x54,0xc9,0xe4,0xc3,0x15,0x4d,0xb3,0x6f,0x2b,0x51,0x57};
    input.timestamp = 1725374568455LL;
    input.nonce = 7598630810654817703ULL;
    const auto pow_a = pepepow::crypto::calculate_pow(input);
    const auto pow_b = pepepow::crypto::calculate_pow(input);
    assert(pow_a == pow_b);
    bool nonzero = false;
    for (const auto byte : pow_a) nonzero = nonzero || byte != 0;
    assert(nonzero);

    const auto direct_a = pepepow::crypto::calculate_header80_pow(header);
    const auto direct_b = pepepow::crypto::calculate_header80_pow(header);
    assert(direct_a == direct_b);

    auto next_header = header;
    next_header[76] ^= 0x01U;
    const auto direct_next = pepepow::crypto::calculate_header80_pow(next_header);
    assert(direct_a != direct_next);

    bool direct_nonzero = false;
    for (const auto byte : direct_a) direct_nonzero = direct_nonzero || byte != 0;
    assert(direct_nonzero);

    return 0;
}
