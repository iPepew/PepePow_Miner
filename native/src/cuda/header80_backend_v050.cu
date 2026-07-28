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

constexpr std::size_t kHashSize = 32;
constexpr std::size_t kMatrixElements = 64 * 64;
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
    host_compress(kHostIv.data(), block, 64, kChunkStart, compressed);

    std::array<std::uint32_t, 8> midstate{};
    std::copy_n(compressed, 8, midstate.begin());
    return midstate;
}

__device__ __forceinline__ std::uint32_t rotr32(std::uint32_t value, int bits) {
    return __funnelshift_r(value, value, bits);
}

__device__ __forceinline__ std::uint32_t byte_swap32(std::uint32_t value) {
    return __byte_perm(value, 0U, 0x0123U);
}

__device__ __forceinline__ void g(
    std::uint32_t& a, std::uint32_t& b, std::uint32_t& c, std::uint32_t& d,
    std::uint32_t mx, std::uint32_t my) {
    a = a + b + mx;
    d = rotr32(d ^ a, 16);
    c += d;
    b = rotr32(b ^ c, 12);
    a = a + b + my;
    d = rotr32(d ^ a, 8);
    c += d;
    b = rotr32(b ^ c, 7);
}

__device__ __forceinline__ void compress_words(
    const std::uint32_t cv[8], const std::uint32_t block[16],
    std::uint32_t block_len, std::uint32_t flags, std::uint32_t out[16]) {
    std::uint32_t v[16];
    #pragma unroll
    for (int i = 0; i < 8; ++i) v[i] = cv[i];
    #pragma unroll
    for (int i = 0; i < 4; ++i) v[8 + i] = kHeader80Iv[i];
    v[12] = 0;
    v[13] = 0;
    v[14] = block_len;
    v[15] = flags;

    #pragma unroll
    for (int round = 0; round < 7; ++round) {
        const std::uint8_t* s = kHeader80Schedule[round];
        g(v[0],v[4],v[8],v[12],block[s[0]],block[s[1]]);
        g(v[1],v[5],v[9],v[13],block[s[2]],block[s[3]]);
        g(v[2],v[6],v[10],v[14],block[s[4]],block[s[5]]);
        g(v[3],v[7],v[11],v[15],block[s[6]],block[s[7]]);
        g(v[0],v[5],v[10],v[15],block[s[8]],block[s[9]]);
        g(v[1],v[6],v[11],v[12],block[s[10]],block[s[11]]);
        g(v[2],v[7],v[8],v[13],block[s[12]],block[s[13]]);
        g(v[3],v[4],v[9],v[14],block[s[14]],block[s[15]]);
    }

    #pragma unroll
    for (int i = 0; i < 8; ++i) {
        out[i] = v[i] ^ v[i + 8];
        out[i + 8] = v[i + 8] ^ cv[i];
    }
}

__device__ __forceinline__ void blake3_header80_words(
    std::uint32_t nonce, std::uint32_t output[8]) {
    std::uint32_t cv[8];
    std::uint32_t block[16];
    std::uint32_t compressed[16];
    #pragma unroll
    for (int i = 0; i < 8; ++i) cv[i] = kHeader80Midstate[i];
    #pragma unroll
    for (int i = 0; i < 16; ++i) block[i] = 0;
    block[0] = kHeader80TailWords[0];
    block[1] = kHeader80TailWords[1];
    block[2] = kHeader80TailWords[2];
    block[3] = byte_swap32(nonce);
    compress_words(cv, block, 16, kChunkEnd | kRoot, compressed);
    #pragma unroll
    for (int i = 0; i < 8; ++i) output[i] = compressed[i];
}

__device__ __forceinline__ void blake3_32_words(
    const std::uint32_t input[8], std::uint32_t output[8]) {
    std::uint32_t cv[8];
    std::uint32_t block[16];
    std::uint32_t compressed[16];
    #pragma unroll
    for (int i = 0; i < 8; ++i) cv[i] = kHeader80Iv[i];
    #pragma unroll
    for (int i = 0; i < 8; ++i) block[i] = input[i];
    #pragma unroll
    for (int i = 8; i < 16; ++i) block[i] = 0;
    compress_words(cv, block, 32, kChunkStart | kChunkEnd | kRoot, compressed);
    #pragma unroll
    for (int i = 0; i < 8; ++i) output[i] = compressed[i];
}

__device__ __forceinline__ double nonlinear(double x) {
    const double one_base = x * kTransformMultiplier / 8.0;
    const double two_base = x * kTransformMultiplier / 4.0;
    const double one = one_base - floor(one_base);
    const double two = two_base - floor(two_base);
    double y;
    if (two < 0.25) y = x + (1.0 + two);
    else if (two < 0.50) y = x - (1.0 + two);
    else if (two < 0.75) y = x * (1.0 + two);
    else y = x / (1.0 + two);
    if (one < 0.33) {
        double sine, cosine;
        sincos(y, &sine, &cosine);
        return exp(sine + cosine);
    }
    if (one < 0.66) {
        if (y == kPi / 2.0 || y == 3.0 * kPi / 2.0) return 0.0;
        const double sine = sin(y);
        return sine * sine;
    }
    return 1.0 / sqrt(fabs(y) + 1.0);
}

__device__ __forceinline__ double safe_nonlinear(double x) {
    double rounds = 1.0;
    double out = nonlinear(x);
    while (isnan(out) || isinf(out)) {
        x *= 0.1;
        if (x <= 1e-13) return 0.0;
        rounds += 1.0;
        out = nonlinear(x);
    }
    return out * rounds;
}

__device__ __forceinline__ std::uint8_t word_byte(
    const std::uint32_t words[8], int byte_index) {
    const std::uint32_t word = words[byte_index >> 2];
    return static_cast<std::uint8_t>(word >> ((byte_index & 3) * 8));
}

__device__ __forceinline__ void accumulate(
    const double* __restrict__ matrix,
    int cell_index, double value, double hash_mod, double nonce_mod,
    double& sum, double& sw) {
    if (sw <= 0.02) {
        if (value != 0.0) {
            const double cell = matrix[cell_index];
            const double x = cell * hash_mod * value + nonce_mod;
            sum += safe_nonlinear(x) * value * 1234.0;
        }
    } else {
#if PEPEPOW_CUDA_SCALED_MATRIX
        sum += kHeader80ScaledMatrix[cell_index] * value;
#else
        sum += matrix[cell_index] * 0.0001 * value;
#endif
    }
    sw = sum / 1024.0 - floor(sum / 1024.0);
}

__device__ __forceinline__ double matrix_row(
    const double* __restrict__ matrix,
    int row, const std::uint32_t first_pass[8], std::uint32_t hash_mod,
    double nonce_mod, double& sw) {
    double sum = 0.0;
    const double hash_mod_fp64 = static_cast<double>(hash_mod);
    const int row_offset = row * 64;
#if PEPEPOW_CUDA_BYTE_UNROLL == 4
    #pragma unroll 4
#elif PEPEPOW_CUDA_BYTE_UNROLL == 2
    #pragma unroll 2
#else
    #pragma unroll 1
#endif
    for (int byte_index = 0; byte_index < 32; ++byte_index) {
        const std::uint8_t packed = word_byte(first_pass, byte_index);
        const int high_cell = row_offset + byte_index * 2;
        const int low_cell = high_cell + 1;
        accumulate(matrix, high_cell, static_cast<double>(packed >> 4U),
                   hash_mod_fp64, nonce_mod, sum, sw);
        accumulate(matrix, low_cell, static_cast<double>(packed & 0x0fU),
                   hash_mod_fp64, nonce_mod, sum, sw);
    }
    return sum;
}

__device__ __forceinline__ bool hash_words_meet_target(
    const std::uint32_t hash_words[8]) {
    #pragma unroll
    for (int i = 0; i < 8; ++i) {
        const std::uint32_t hash_be = byte_swap32(hash_words[i]);
        const std::uint32_t target_be = kHeader80TargetWords[i];
        if (hash_be < target_be) return true;
        if (hash_be > target_be) return false;
    }
    return true;
}

__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void header80_pow_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    DeviceShareResult* __restrict__ result,
    std::size_t count) {
    const std::size_t index = static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) return;

    const std::uint32_t nonce = first_nonce + static_cast<std::uint32_t>(index);
    const std::uint32_t mix_nonce = byte_swap32(nonce);

    std::uint32_t first_pass[8];
    std::uint32_t mixed[8];
    std::uint32_t final_hash[8];
    blake3_header80_words(nonce, first_pass);

    std::uint32_t hash_xor = 0;
    #pragma unroll
    for (int i = 0; i < 8; ++i) {
        hash_xor ^= first_pass[i];
        mixed[i] = first_pass[i];
    }
    const std::uint32_t hash_mod = byte_swap32(hash_xor);

    const double nonce_mod = static_cast<double>(mix_nonce & 0xffU);
    double sw = 0.0;
    #pragma unroll 1
    for (int pair = 0; pair < 32; ++pair) {
        const double even_sum = matrix_row(matrix, pair * 2, first_pass, hash_mod, nonce_mod, sw);
        const double odd_sum = matrix_row(matrix, pair * 2 + 1, first_pass, hash_mod, nonce_mod, sw);
        const std::uint64_t combined = static_cast<std::uint64_t>(even_sum) +
                                       static_cast<std::uint64_t>(odd_sum);
        const std::uint32_t shift = static_cast<std::uint32_t>((pair & 3) * 8);
        mixed[pair >> 2] ^= static_cast<std::uint32_t>(combined & 0xffU) << shift;
    }

    blake3_32_words(mixed, final_hash);
    if (!hash_words_meet_target(final_hash)) return;

    if (atomicCAS(&result->found, 0U, 1U) == 0U) {
        result->nonce = nonce;
        #pragma unroll
        for (int i = 0; i < 8; ++i) result->hash_words[i] = final_hash[i];
    }
}

} // namespace

Header80CudaBackend::Header80CudaBackend(int device_index) : device_index_(device_index) {}

Header80CudaBackend::~Header80CudaBackend() {
    if (device_result_ != nullptr || device_matrix_ != nullptr) {
        cudaSetDevice(device_index_);
    }
    if (device_result_ != nullptr) {
        cudaFree(device_result_);
        device_result_ = nullptr;
    }
    if (device_matrix_ != nullptr) {
        cudaFree(device_matrix_);
        device_matrix_ = nullptr;
    }
}

std::string_view Header80CudaBackend::name() const noexcept { return "cuda-header80-word-pipeline"; }

std::vector<DeviceInfo> Header80CudaBackend::enumerate_devices() const {
    int count = 0;
    check_cuda_header80(cudaGetDeviceCount(&count), "cudaGetDeviceCount");
    std::vector<DeviceInfo> devices;
    devices.reserve(static_cast<std::size_t>(count));
    for (int index = 0; index < count; ++index) {
        cudaDeviceProp properties{};
        check_cuda_header80(cudaGetDeviceProperties(&properties, index), "cudaGetDeviceProperties");
        devices.push_back(DeviceInfo{index, properties.name, properties.major,
                                     properties.minor, properties.totalGlobalMem});
    }
    return devices;
}

std::optional<ShareCandidate> Header80CudaBackend::search(
    const MiningJob& job,
    SearchRange range,
    std::span<const std::uint8_t, 32> target) {
    if (range.count == 0 || range.begin > std::numeric_limits<std::uint32_t>::max()) {
        return std::nullopt;
    }

    const std::uint64_t max_count = 0x100000000ULL - range.begin;
    const std::size_t count = static_cast<std::size_t>(std::min(range.count, max_count));
    if (count == 0) return std::nullopt;

    MiningJob base_job = job;
    base_job.nonce = 0U;
    const Header80 header = build_header80(base_job);
    Header80 masked_header = header;
    std::fill(masked_header.begin() + 76, masked_header.end(), 0U);
    const crypto::Hash256 matrix_seed = crypto::blake3_hash(masked_header);

    check_cuda_header80(cudaSetDevice(device_index_), "cudaSetDevice(header80)");

    static thread_local bool header_cached = false;
    static thread_local int cached_device = -1;
    static thread_local crypto::Hash256 cached_matrix_seed{};
    if (device_matrix_ == nullptr || !header_cached || cached_device != device_index_ || cached_matrix_seed != matrix_seed) {
        const crypto::HoohashMatrix matrix = crypto::generate_hoohash_matrix(matrix_seed);
        if (device_matrix_ == nullptr) {
            check_cuda_header80(cudaMalloc(&device_matrix_, kMatrixElements * sizeof(double)),
                                "cudaMalloc(header80 matrix)");
        }
        check_cuda_header80(
            cudaMemcpy(device_matrix_, matrix.data()->data(),
                       kMatrixElements * sizeof(double), cudaMemcpyHostToDevice),
            "cudaMemcpy(header80 matrix)");
#if PEPEPOW_CUDA_SCALED_MATRIX
        std::array<double, kMatrixElements> scaled_matrix{};
        const double* matrix_values = matrix.data()->data();
        for (std::size_t cell = 0; cell < kMatrixElements; ++cell) {
            scaled_matrix[cell] = matrix_values[cell] * 0.0001;
        }
        check_cuda_header80(
            cudaMemcpyToSymbol(kHeader80ScaledMatrix, scaled_matrix.data(),
                               kMatrixElements * sizeof(double), 0, cudaMemcpyHostToDevice),
            "cudaMemcpyToSymbol(header80 scaled matrix)");
#endif
        const auto midstate = first_block_midstate(header);
        const std::array<std::uint32_t, 3> tail_words{
            host_load_le32(header.data() + 64),
            host_load_le32(header.data() + 68),
            host_load_le32(header.data() + 72)};
        check_cuda_header80(
            cudaMemcpyToSymbol(kHeader80Midstate, midstate.data(), sizeof(midstate),
                               0, cudaMemcpyHostToDevice),
            "cudaMemcpyToSymbol(header80 midstate)");
        check_cuda_header80(
            cudaMemcpyToSymbol(kHeader80TailWords, tail_words.data(), sizeof(tail_words),
                               0, cudaMemcpyHostToDevice),
            "cudaMemcpyToSymbol(header80 tail)");
        cached_matrix_seed = matrix_seed;
        cached_device = device_index_;
        header_cached = true;
    }

    static thread_local bool target_cached = false;
    static thread_local std::array<std::uint8_t, 32> cached_target{};
    std::array<std::uint8_t, 32> target_copy{};
    std::copy(target.begin(), target.end(), target_copy.begin());
    if (!target_cached || cached_target != target_copy) {
        std::array<std::uint32_t, 8> target_words{};
        for (int i = 0; i < 8; ++i) {
            target_words[static_cast<std::size_t>(i)] = host_load_be32(target.data() + i * 4);
        }
        check_cuda_header80(
            cudaMemcpyToSymbol(kHeader80TargetWords, target_words.data(), sizeof(target_words),
                               0, cudaMemcpyHostToDevice),
            "cudaMemcpyToSymbol(header80 target words)");
        cached_target = target_copy;
        target_cached = true;
    }

    if (device_result_ == nullptr) {
        check_cuda_header80(cudaMalloc(&device_result_, sizeof(DeviceShareResult)),
                            "cudaMalloc(header80 result)");
    }
    check_cuda_header80(cudaMemset(device_result_, 0, sizeof(std::uint32_t)),
                        "cudaMemset(header80 found flag)");

    constexpr unsigned int threads = static_cast<unsigned int>(PEPEPOW_CUDA_THREADS);
    const unsigned int blocks = static_cast<unsigned int>((count + threads - 1U) / threads);
    header80_pow_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<DeviceShareResult*>(device_result_),
        count);
    check_cuda_header80(cudaGetLastError(), "header80_pow_kernel launch");

    DeviceShareResult host_result{};
    check_cuda_header80(
        cudaMemcpy(&host_result, device_result_, sizeof(host_result), cudaMemcpyDeviceToHost),
        "cudaMemcpy(header80 result)");
    if (host_result.found == 0U) return std::nullopt;

    Hash256 hash{};
    for (int word_index = 0; word_index < 8; ++word_index) {
        const std::uint32_t word = host_result.hash_words[word_index];
        hash[static_cast<std::size_t>(word_index * 4)] = static_cast<std::uint8_t>(word);
        hash[static_cast<std::size_t>(word_index * 4 + 1)] = static_cast<std::uint8_t>(word >> 8U);
        hash[static_cast<std::size_t>(word_index * 4 + 2)] = static_cast<std::uint8_t>(word >> 16U);
        hash[static_cast<std::size_t>(word_index * 4 + 3)] = static_cast<std::uint8_t>(word >> 24U);
    }
    return ShareCandidate{job.job_id, host_result.nonce, hash};
}

} // namespace pepepow
