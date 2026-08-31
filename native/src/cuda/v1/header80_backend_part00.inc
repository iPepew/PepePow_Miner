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
#ifndef PEPEPOW_CUDA_COLD_OUTLINE
#define PEPEPOW_CUDA_COLD_OUTLINE 0
#endif
#ifndef PEPEPOW_CUDA_HOTRUN8_WORD_STREAM
#define PEPEPOW_CUDA_HOTRUN8_WORD_STREAM 0
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
