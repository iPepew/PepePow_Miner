#include "pepepow/cuda/header80_backend.hpp"

#include "pepepow/core/header_builder.hpp"
#include "pepepow/crypto/blake3.hpp"
#include "pepepow/crypto/hoohash_reference.hpp"

#include <cuda_runtime.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace pepepow {
namespace {

#ifndef PEPEPOW_CUDA_THREADS
#define PEPEPOW_CUDA_THREADS 64
#endif
#ifndef PEPEPOW_CUDA_MIN_BLOCKS
#define PEPEPOW_CUDA_MIN_BLOCKS 1
#endif
#ifndef PEPEPOW_CUDA_HOOHASH_THREADS
#define PEPEPOW_CUDA_HOOHASH_THREADS PEPEPOW_CUDA_THREADS
#endif
#ifndef PEPEPOW_CUDA_HOOHASH_MIN_BLOCKS
#define PEPEPOW_CUDA_HOOHASH_MIN_BLOCKS PEPEPOW_CUDA_MIN_BLOCKS
#endif
#ifndef PEPEPOW_CUDA_BLAKE_THREADS
#define PEPEPOW_CUDA_BLAKE_THREADS PEPEPOW_CUDA_THREADS
#endif
#ifndef PEPEPOW_CUDA_BLAKE_MIN_BLOCKS
#define PEPEPOW_CUDA_BLAKE_MIN_BLOCKS PEPEPOW_CUDA_MIN_BLOCKS
#endif
#ifndef PEPEPOW_CUDA_SCALED_MATRIX
#define PEPEPOW_CUDA_SCALED_MATRIX 1
#endif
#ifndef PEPEPOW_CUDA_BYTE_UNROLL
#define PEPEPOW_CUDA_BYTE_UNROLL 1
#endif
#ifndef PEPEPOW_CUDA_SPLIT_PIPELINE
#define PEPEPOW_CUDA_SPLIT_PIPELINE 1
#endif
#ifndef PEPEPOW_CUDA_FAST_FRACTION
#define PEPEPOW_CUDA_FAST_FRACTION 1
#endif
#ifndef PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS
#define PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS 1
#endif
#ifndef PEPEPOW_CUDA_BIT_SW_FRACTION
#define PEPEPOW_CUDA_BIT_SW_FRACTION 1
#endif
#ifndef PEPEPOW_CUDA_DERIVE_TWO
#define PEPEPOW_CUDA_DERIVE_TWO 1
#endif
#ifndef PEPEPOW_CUDA_NIBBLE_TABLE
#define PEPEPOW_CUDA_NIBBLE_TABLE 0
#endif
#ifndef PEPEPOW_CUDA_SCALED_NIBBLE_TABLE
#define PEPEPOW_CUDA_SCALED_NIBBLE_TABLE 0
#endif
#ifndef PEPEPOW_CUDA_ASSUME_FINITE
#define PEPEPOW_CUDA_ASSUME_FINITE 0
#endif
#ifndef PEPEPOW_CUDA_SW_STATE_MODE
#define PEPEPOW_CUDA_SW_STATE_MODE 0
#endif

constexpr std::size_t kHashSize = 32;
constexpr std::size_t kMatrixElements = 64 * 64;
constexpr std::size_t kScaledNibbleElements = kMatrixElements * 16;
constexpr double kPi = 3.14159265358979323846;
constexpr double kTransformMultiplier = 0.000001;
constexpr std::uint32_t kChunkStart = 1U;
constexpr std::uint32_t kChunkEnd = 2U;
constexpr std::uint32_t kRoot = 8U;

constexpr std::array<std::uint32_t, 8> kHostIv{
    0x6A09E667U, 0xBB67AE85U, 0x3C6EF372U, 0xA54FF53AU,
    0x510E527FU, 0x9B05688CU, 0x1F83D9ABU, 0x5BE0CD19U};
constexpr std::uint8_t kHostSchedule[7][16] = {
    {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15},
    {2,6,3,10,7,0,4,13,1,11,12,5,9,14,15,8},
    {3,4,10,12,13,2,7,14,6,5,9,0,11,15,8,1},
    {10,7,12,9,14,3,13,15,4,0,11,2,5,8,1,6},
    {12,13,9,11,15,10,14,8,7,2,5,3,0,1,6,4},
    {9,14,11,5,8,12,15,1,13,3,0,10,2,6,4,7},
    {11,15,5,0,1,9,8,6,14,10,2,12,3,4,7,13}};

__device__ __constant__ double kHeader80ScaledMatrix[kMatrixElements];
__device__ __constant__ std::uint32_t kHeader80Midstate[8];
__device__ __constant__ std::uint32_t kHeader80TailWords[3];
__device__ __constant__ std::uint32_t kHeader80TargetWords[8];
__device__ __constant__ double kHeader80NibbleFp64[16] = {
    0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0,
    8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0};
__device__ __constant__ std::uint32_t kHeader80Iv[8] = {
    0x6A09E667U, 0xBB67AE85U, 0x3C6EF372U, 0xA54FF53AU,
    0x510E527FU, 0x9B05688CU, 0x1F83D9ABU, 0x5BE0CD19U};
__device__ __constant__ std::uint8_t kHeader80Schedule[7][16] = {
    {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15},
    {2,6,3,10,7,0,4,13,1,11,12,5,9,14,15,8},
    {3,4,10,12,13,2,7,14,6,5,9,0,11,15,8,1},
    {10,7,12,9,14,3,13,15,4,0,11,2,5,8,1,6},
    {12,13,9,11,15,10,14,8,7,2,5,3,0,1,6,4},
    {9,14,11,5,8,12,15,1,13,3,0,10,2,6,4,7},
    {11,15,5,0,1,9,8,6,14,10,2,12,3,4,7,13}};

struct DeviceShareResult {
    std::uint32_t found{0};
    std::uint32_t nonce{0};
    std::uint32_t hash_words[8]{};
};

void check_cuda_header80(cudaError_t status, const char* operation) {
    if (status != cudaSuccess) {
        throw std::runtime_error(std::string(operation) + ": " + cudaGetErrorString(status));
    }
}

constexpr std::uint32_t host_rotr32(std::uint32_t value, int bits) noexcept {
    return (value >> bits) | (value << (32 - bits));
}

void host_g(
    std::uint32_t& a, std::uint32_t& b, std::uint32_t& c, std::uint32_t& d,
    std::uint32_t mx, std::uint32_t my) noexcept {
    a = a + b + mx;
    d = host_rotr32(d ^ a, 16);
    c += d;
    b = host_rotr32(b ^ c, 12);
    a = a + b + my;
    d = host_rotr32(d ^ a, 8);
    c += d;
    b = host_rotr32(b ^ c, 7);
}

std::uint32_t host_load_le32(const std::uint8_t* p) noexcept {
    return static_cast<std::uint32_t>(p[0]) |
           (static_cast<std::uint32_t>(p[1]) << 8U) |
           (static_cast<std::uint32_t>(p[2]) << 16U) |
           (static_cast<std::uint32_t>(p[3]) << 24U);
}

std::uint32_t host_load_be32(const std::uint8_t* p) noexcept {
    return (static_cast<std::uint32_t>(p[0]) << 24U) |
           (static_cast<std::uint32_t>(p[1]) << 16U) |
           (static_cast<std::uint32_t>(p[2]) << 8U) |
           static_cast<std::uint32_t>(p[3]);
}

void host_compress(
    const std::uint32_t cv[8], const std::uint32_t block[16],
    std::uint32_t block_len, std::uint32_t flags, std::uint32_t out[16]) noexcept {
    std::uint32_t v[16];
    for (int i = 0; i < 8; ++i) v[i] = cv[i];
    for (int i = 0; i < 4; ++i) v[8 + i] = kHostIv[static_cast<std::size_t>(i)];
    v[12] = 0;
    v[13] = 0;
    v[14] = block_len;
    v[15] = flags;

    for (int round = 0; round < 7; ++round) {
        const std::uint8_t* s = kHostSchedule[round];
        host_g(v[0],v[4],v[8],v[12],block[s[0]],block[s[1]]);
        host_g(v[1],v[5],v[9],v[13],block[s[2]],block[s[3]]);
        host_g(v[2],v[6],v[10],v[14],block[s[4]],block[s[5]]);
        host_g(v[3],v[7],v[11],v[15],block[s[6]],block[s[7]]);
        host_g(v[0],v[5],v[10],v[15],block[s[8]],block[s[9]]);
        host_g(v[1],v[6],v[11],v[12],block[s[10]],block[s[11]]);
        host_g(v[2],v[7],v[8],v[13],block[s[12]],block[s[13]]);
        host_g(v[3],v[4],v[9],v[14],block[s[14]],block[s[15]]);
    }

    for (int i = 0; i < 8; ++i) {
        out[i] = v[i] ^ v[i + 8];
        out[i + 8] = v[i + 8] ^ cv[i];
    }
}

std::array<std::uint32_t, 8> first_block_midstate(const Header80& header) noexcept {
    std::uint32_t block[16]{};
    std::uint32_t compressed[16]{};
    for (int i = 0; i < 16; ++i) block[i] = host_load_le32(header.data() + i * 4);
