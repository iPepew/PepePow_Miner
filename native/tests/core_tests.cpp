#include "pepepow/core/header_builder.hpp"
#include "pepepow/crypto/blake3.hpp"
#include "pepepow/crypto/hoohash_reference.hpp"
#include "pepepow/crypto/pow.hpp"
#include "pepepow/mining/target.hpp"
#include "pepepow/stratum/client.hpp"

#include <algorithm>
#include <array>
#include <cassert>
#include <cmath>
#include <cstddef>
#include <cstdint>

namespace {

std::uint32_t load_le32(const std::uint8_t* value) noexcept {
    return static_cast<std::uint32_t>(value[0]) |
           (static_cast<std::uint32_t>(value[1]) << 8U) |
           (static_cast<std::uint32_t>(value[2]) << 16U) |
           (static_cast<std::uint32_t>(value[3]) << 24U);
}

} // namespace

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
    assert(header[0] == 0x44U && header[1] == 0x33U && header[2] == 0x22U && header[3] == 0x11U);
    assert(header[68] == 0x88U && header[69] == 0x77U && header[70] == 0x66U && header[71] == 0x55U);
    assert(header[72] == 0xccU && header[73] == 0xbbU && header[74] == 0xaaU && header[75] == 0x99U);

    // Pool protocol invariant: the submit nonce is LE hex, the pool reverses it
    // into BE32 Header80 bytes, then decodes those bytes as LE32 for HooHash.
    assert(header[76] == 0xddU && header[77] == 0xeeU && header[78] == 0xffU && header[79] == 0x00U);
    assert(pepepow::stratum::encode_u32_le_hex(job.nonce) == "00ffeedd");
    assert(load_le32(header.data() + 76) == 0x00ffeeddU);

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

    // Independent pool-reference reconstruction. This guards against both bugs
    // found by live pool traces: seeding the matrix from prevhash and passing the
    // wrong numeric nonce into the nonlinear matrix stage.
    auto masked_header = header;
    std::fill(masked_header.begin() + 76, masked_header.end(), 0U);
    const auto pool_matrix_seed = pepepow::crypto::blake3_hash(masked_header);
    const auto pool_header_hash = pepepow::crypto::blake3_hash(header);
    const auto pool_matrix = pepepow::crypto::generate_hoohash_matrix(pool_matrix_seed);
    const auto pool_mixed = pepepow::crypto::hoohash_matrix_mix(
        pool_matrix, pool_header_hash, load_le32(header.data() + 76));
    const auto pool_reference_hash = pepepow::crypto::blake3_hash(pool_mixed);
    assert(direct_a == pool_reference_hash);

    auto next_header = header;
    next_header[79] ^= 0x01U;
    const auto direct_next = pepepow::crypto::calculate_header80_pow(next_header);
    assert(direct_a != direct_next);

    bool direct_nonzero = false;
    for (const auto byte : direct_a) direct_nonzero = direct_nonzero || byte != 0;
    assert(direct_nonzero);

    const auto diff1 = pepepow::mining::target_from_difficulty(
        pepepow::mining::kStratumDifficultyWireScale);
    assert(diff1[0] == 0x00U && diff1[1] == 0x00U);
    assert(diff1[2] == 0x00U && diff1[3] == 0x00U);
    assert(diff1[4] == 0xffU && diff1[5] == 0xffU);
    for (std::size_t index = 6; index < diff1.size(); ++index) assert(diff1[index] == 0U);

    const auto diff2 = pepepow::mining::target_from_difficulty(
        2.0 * pepepow::mining::kStratumDifficultyWireScale);
    assert(diff2 < diff1);

    const auto pool_target = pepepow::mining::target_from_difficulty(98.304);
    assert(pool_target > diff1);
    assert(pool_target[0] == 0x00U);
    assert(pool_target[1] == 0x00U);
    assert(pool_target[2] >= 0x02U && pool_target[2] <= 0x03U);

    pepepow::Hash256 accepted_like{
        0x00,0x00,0x01,0xf7,0xda,0x52,0x4f,0x1f,0x43,0x5e,0xba,0xf9,0x5b,0x10,0x49,0xc7,
        0x20,0xa5,0xed,0x84,0x4e,0x26,0x2a,0x48,0x6c,0xab,0xa0,0x5b,0x84,0x04,0x65,0xde};
    assert(pepepow::mining::hash_meets_target_be(accepted_like, pool_target));

    pepepow::Hash256 rejected_like{
        0x00,0x3a,0x27,0x0b,0xe1,0x9d,0xdc,0xa9,0xaf,0xbd,0x12,0x0f,0x4b,0x4a,0xb9,0xe4,
        0x58,0x3c,0x97,0x63,0x4b,0x9c,0x37,0x03,0xad,0xfe,0x20,0x15,0xa1,0x67,0x32,0x75};
    assert(!pepepow::mining::hash_meets_target_be(rejected_like, pool_target));

    pepepow::Hash256 zero_hash{};
    assert(pepepow::mining::hash_meets_target_be(zero_hash, diff1));
    pepepow::Hash256 max_hash{};
    max_hash.fill(0xffU);
    assert(!pepepow::mining::hash_meets_target_be(max_hash, diff1));

    return 0;
}
