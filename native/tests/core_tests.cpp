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
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string_view>

namespace {

std::uint32_t load_le32(const std::uint8_t* value) noexcept {
    return static_cast<std::uint32_t>(value[0]) |
           (static_cast<std::uint32_t>(value[1]) << 8U) |
           (static_cast<std::uint32_t>(value[2]) << 16U) |
           (static_cast<std::uint32_t>(value[3]) << 24U);
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

template <typename Container>
void print_hex(const Container& value) {
    std::ios old_state(nullptr);
    old_state.copyfmt(std::cerr);
    std::cerr << std::hex << std::setfill('0');
    for (const auto byte : value) {
        std::cerr << std::setw(2) << static_cast<unsigned>(byte);
    }
    std::cerr.copyfmt(old_state);
}

struct ConsensusVector {
    std::string_view name;
    std::string_view header_hex;
    std::string_view expected_hash_hex;
};

bool validate_consensus_vector(const ConsensusVector& vector) {
    const auto header = parse_hex<80>(vector.header_hex);
    const auto expected = parse_hex<32>(vector.expected_hash_hex);
    const auto actual = pepepow::crypto::calculate_header80_pow(header);
    if (actual == expected) return true;

    std::cerr << "CONSENSUS_VECTOR_FAIL name=" << vector.name << "\nexpected=";
    print_hex(expected);
    std::cerr << "\nactual=";
    print_hex(actual);
    std::cerr << '\n';
    return false;
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

    constexpr ConsensusVector authoritative_vector{
        "authoritative-known-chain",
        "0040002038e31388c54124146478ff691985eecd02610db91efbc9cd7aabca4900000000"
        "07647f0508057dbf8c99ddaa87543c04e31dfe3f383e7386903d50c91728fabe8"
        "30be16971e3021da96d9d33",
        "00000001fb895a82973fca52938848908d6a6cb3c0dfb93995dc61020ced0a6b"};
    if (!validate_consensus_vector(authoritative_vector)) return 1;
    std::cout << "PASS: authoritative HooHash V110 vector matched\n";

    constexpr std::array<ConsensusVector, 4> live_vectors{{
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
    for (const auto& vector : live_vectors) {
        if (!validate_consensus_vector(vector)) return 1;
    }
    std::cout << "PASS: 4 live consensus HooHash vectors matched\n";

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

    // Live pool target semantics: the current job's nBits target is divided by
    // the normalized Stratum difficulty. Using Bitcoin's fixed diff1 target was
    // about 5-6% too loose and caused sporadic boundary rejects.
    const auto network_target_9227 = pepepow::mining::target_from_compact(0x1d00efd1U);
    assert(network_target_9227 == parse_hex<32>(
        "00000000efd10000000000000000000000000000000000000000000000000000"));

    const auto target_9227 = pepepow::mining::target_from_difficulty(
        147.244253, 0x1d00efd1U);
    assert(target_9227 == parse_hex<32>(
        "000001a0f258869aae0950088db758d97aaf03ef3d225def5ac3f1130b9f5f25"));

    const auto accepted_9227 = parse_hex<32>(
        "000000f91b47a38ff3ff6f17325c23810a15889327eac5bd7ddae84edbd95264");
    const auto rejected_boundary_9227 = parse_hex<32>(
        "000001b62bf412b224e8d3135e55c861e063756ec774c1034d554f81eaf2624e");
    assert(pepepow::mining::hash_meets_target_be(accepted_9227, target_9227));
    assert(!pepepow::mining::hash_meets_target_be(rejected_boundary_9227, target_9227));

    const auto target_92a1 = pepepow::mining::target_from_difficulty(
        113.527280, 0x1d00f11fU);
    assert(target_92a1 == parse_hex<32>(
        "0000021fb8337ec9b6dd9d971b4006d7398101c1cb2caf158046e7ee46b12245"));
    const auto rejected_boundary_92a1 = parse_hex<32>(
        "0000023e5c0053e212a6120eb79660c897f8681a7436f2f86a09897264f3a31d");
    assert(!pepepow::mining::hash_meets_target_be(rejected_boundary_92a1, target_92a1));

    const auto network_at_one = pepepow::mining::target_from_difficulty(
        pepepow::mining::kStratumDifficultyWireScale, 0x1d00efd1U);
    assert(network_at_one == network_target_9227);
    const auto half_target = pepepow::mining::target_from_difficulty(
        2.0 * pepepow::mining::kStratumDifficultyWireScale, 0x1d00efd1U);
    assert(half_target < network_at_one);

    pepepow::Hash256 zero_hash{};
    assert(pepepow::mining::hash_meets_target_be(zero_hash, target_9227));
    pepepow::Hash256 max_hash{};
    max_hash.fill(0xffU);
    assert(!pepepow::mining::hash_meets_target_be(max_hash, target_9227));

    std::cout << "PASS: live nBits share-target boundaries matched\n";
    return 0;
}
