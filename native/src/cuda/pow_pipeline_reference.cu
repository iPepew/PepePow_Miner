#include "pepepow/cuda/cuda_backend.hpp"

#include <cuda_runtime.h>

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <stdexcept>
#include <string>
#include <vector>

namespace pepepow {
namespace {

constexpr std::size_t kHashSize = 32;
constexpr std::size_t kMatrixElements = 64 * 64;
constexpr double kPi = 3.14159265358979323846;
constexpr double kTransformMultiplier = 0.000001;
constexpr std::uint32_t kChunkStart = 1U;
constexpr std::uint32_t kChunkEnd = 2U;
constexpr std::uint32_t kRoot = 8U;

__device__ __constant__ double kPipelineMatrix[kMatrixElements];

__device__ __constant__ std::uint32_t kPipelineIv[8] = {
    0x6A09E667U, 0xBB67AE85U, 0x3C6EF372U, 0xA54FF53AU,
    0x510E527FU, 0x9B05688CU, 0x1F83D9ABU, 0x5BE0CD19U};

__device__ __constant__ std::uint8_t kPipelineSchedule[7][16] = {
    {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
    {2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8},
    {3, 4, 10, 12, 13, 2, 7, 14, 6, 5, 9, 0, 11, 15, 8, 1},
    {10, 7, 12, 9, 14, 3, 13, 15, 4, 0, 11, 2, 5, 8, 1, 6},
    {12, 13, 9, 11, 15, 10, 14, 8, 7, 2, 5, 3, 0, 1, 6, 4},
    {9, 14, 11, 5, 8, 12, 15, 1, 13, 3, 0, 10, 2, 6, 4, 7},
    {11, 15, 5, 0, 1, 9, 8, 6, 14, 10, 2, 12, 3, 4, 7, 13}};

void check_cuda_pipeline(cudaError_t status, const char* operation) {
    if (status != cudaSuccess) {
        throw std::runtime_error(std::string(operation) + ": " + cudaGetErrorString(status));
    }
}

__device__ __forceinline__ std::uint32_t rotr32_pipeline(std::uint32_t value, int bits) {
    return __funnelshift_r(value, value, bits);
}

__device__ __forceinline__ void g_pipeline(
    std::uint32_t& a, std::uint32_t& b, std::uint32_t& c, std::uint32_t& d,
    std::uint32_t mx, std::uint32_t my) {
    a = a + b + mx;
    d = rotr32_pipeline(d ^ a, 16);
    c += d;
    b = rotr32_pipeline(b ^ c, 12);
    a = a + b + my;
    d = rotr32_pipeline(d ^ a, 8);
    c += d;
    b = rotr32_pipeline(b ^ c, 7);
}

__device__ void compress_pipeline(
    const std::uint32_t cv[8], const std::uint32_t block[16],
    std::uint32_t block_len, std::uint32_t flags, std::uint32_t out[16]) {
    std::uint32_t v[16];
    #pragma unroll
    for (int i = 0; i < 8; ++i) v[i] = cv[i];
    #pragma unroll
    for (int i = 0; i < 4; ++i) v[8 + i] = kPipelineIv[i];
    v[12] = 0;
    v[13] = 0;
    v[14] = block_len;
    v[15] = flags;

    #pragma unroll
    for (int round = 0; round < 7; ++round) {
        const std::uint8_t* s = kPipelineSchedule[round];
        g_pipeline(v[0], v[4], v[8], v[12], block[s[0]], block[s[1]]);
        g_pipeline(v[1], v[5], v[9], v[13], block[s[2]], block[s[3]]);
        g_pipeline(v[2], v[6], v[10], v[14], block[s[4]], block[s[5]]);
        g_pipeline(v[3], v[7], v[11], v[15], block[s[6]], block[s[7]]);
        g_pipeline(v[0], v[5], v[10], v[15], block[s[8]], block[s[9]]);
        g_pipeline(v[1], v[6], v[11], v[12], block[s[10]], block[s[11]]);
        g_pipeline(v[2], v[7], v[8], v[13], block[s[12]], block[s[13]]);
        g_pipeline(v[3], v[4], v[9], v[14], block[s[14]], block[s[15]]);
    }

    #pragma unroll
    for (int i = 0; i < 8; ++i) {
        out[i] = v[i] ^ v[i + 8];
        out[i + 8] = v[i + 8] ^ cv[i];
    }
}

__device__ __forceinline__ std::uint32_t load_le32_pipeline(const std::uint8_t* p) {
    return static_cast<std::uint32_t>(p[0]) |
           (static_cast<std::uint32_t>(p[1]) << 8U) |
           (static_cast<std::uint32_t>(p[2]) << 16U) |
           (static_cast<std::uint32_t>(p[3]) << 24U);
}

__device__ __forceinline__ std::uint32_t load_be32_pipeline(const std::uint8_t* p) {
    return (static_cast<std::uint32_t>(p[0]) << 24U) |
           (static_cast<std::uint32_t>(p[1]) << 16U) |
           (static_cast<std::uint32_t>(p[2]) << 8U) |
           static_cast<std::uint32_t>(p[3]);
}

__device__ __forceinline__ void store_le32_pipeline(std::uint8_t* p, std::uint32_t v) {
    p[0] = static_cast<std::uint8_t>(v);
    p[1] = static_cast<std::uint8_t>(v >> 8U);
    p[2] = static_cast<std::uint8_t>(v >> 16U);
    p[3] = static_cast<std::uint8_t>(v >> 24U);
}

__device__ void blake3_header_pipeline(
    const std::uint8_t previous_header[32],
    std::uint64_t timestamp,
    std::uint64_t nonce,
    std::uint8_t output[32]) {
    std::uint32_t cv[8], block[16], compressed[16];

    #pragma unroll
    for (int i = 0; i < 8; ++i) cv[i] = kPipelineIv[i];

    #pragma unroll
    for (int i = 0; i < 8; ++i) block[i] = load_le32_pipeline(previous_header + i * 4);
    block[8] = static_cast<std::uint32_t>(timestamp);
    block[9] = static_cast<std::uint32_t>(timestamp >> 32U);
    #pragma unroll
    for (int i = 10; i < 16; ++i) block[i] = 0;

    compress_pipeline(cv, block, 64, kChunkStart, compressed);

    #pragma unroll
    for (int i = 0; i < 8; ++i) cv[i] = compressed[i];
    #pragma unroll
    for (int i = 0; i < 16; ++i) block[i] = 0;
    block[2] = static_cast<std::uint32_t>(nonce);
    block[3] = static_cast<std::uint32_t>(nonce >> 32U);

    compress_pipeline(cv, block, 16, kChunkEnd | kRoot, compressed);

    #pragma unroll
    for (int i = 0; i < 8; ++i) store_le32_pipeline(output + i * 4, compressed[i]);
}

__device__ void blake3_32_pipeline(const std::uint8_t input[32], std::uint8_t output[32]) {
    std::uint32_t cv[8], block[16], compressed[16];
    #pragma unroll
    for (int i = 0; i < 8; ++i) cv[i] = kPipelineIv[i];
    #pragma unroll
    for (int i = 0; i < 16; ++i) block[i] = 0;
    #pragma unroll
    for (int i = 0; i < 8; ++i) block[i] = load_le32_pipeline(input + i * 4);
    compress_pipeline(cv, block, 32, kChunkStart | kChunkEnd | kRoot, compressed);
    #pragma unroll
    for (int i = 0; i < 8; ++i) store_le32_pipeline(output + i * 4, compressed[i]);
}

__device__ __forceinline__ double nonlinear_pipeline(double x) {
    const double one_base = x * kTransformMultiplier / 8.0;
    const double two_base = x * kTransformMultiplier / 4.0;
    const double one = one_base - floor(one_base);
    const double two = two_base - floor(two_base);
    double y;
    if (two < 0.25) y = x + 1.0 + two;
    else if (two < 0.50) y = x - 1.0 - two;
    else if (two < 0.75) y = x * (1.0 + two);
    else y = x / (1.0 + two);
    if (one < 0.33) {
        double sine;
        double cosine;
        sincos(y, &sine, &cosine);
        return exp(sine + cosine);
    }
    if (one < 0.66) {
        if (y == kPi / 2.0 || y == 3.0 * kPi / 2.0) return 0.0;
        const double s = sin(y);
        return s * s;
    }
    return 1.0 / sqrt(fabs(y) + 1.0);
}

__device__ __forceinline__ double safe_nonlinear_pipeline(double x) {
    double rounds = 1.0;
    double out = nonlinear_pipeline(x);
    while (isnan(out) || isinf(out)) {
        x *= 0.1;
        if (x <= 1e-13) return 0.0;
        rounds += 1.0;
        out = nonlinear_pipeline(x);
    }
    return out * rounds;
}

__device__ __forceinline__ void accumulate_matrix_cell(
    double cell,
    double value,
    double hash_mod,
    double nonce_mod,
    double& sum,
    double& sw) {
    if (sw <= 0.02) {
        const double x = cell * hash_mod * value + nonce_mod;
        sum += safe_nonlinear_pipeline(x) * value * 1234.0;
    } else {
        sum += cell * 0.0001 * value;
    }
    sw = sum / 1024.0 - floor(sum / 1024.0);
}

__device__ double calculate_matrix_row(
    int row,
    const std::uint8_t first_pass[32],
    std::uint32_t hash_mod,
    double nonce_mod,
    double& sw) {
    double sum = 0.0;
    const double hash_mod_fp64 = static_cast<double>(hash_mod);
    const int row_offset = row * 64;

    #pragma unroll 1
    for (int byte_index = 0; byte_index < 32; ++byte_index) {
        const std::uint8_t packed = first_pass[byte_index];
        const double high_nibble = static_cast<double>(packed >> 4U);
        const double low_nibble = static_cast<double>(packed & 0x0fU);
        const int column = byte_index * 2;

        accumulate_matrix_cell(
            kPipelineMatrix[row_offset + column], high_nibble,
            hash_mod_fp64, nonce_mod, sum, sw);
        accumulate_matrix_cell(
            kPipelineMatrix[row_offset + column + 1], low_nibble,
            hash_mod_fp64, nonce_mod, sum, sw);
    }
    return sum;
}

__global__ void pow_pipeline_kernel(
    const std::uint8_t* __restrict__ previous_header,
    std::uint64_t timestamp,
    std::uint64_t first_nonce,
    std::uint8_t* __restrict__ hashes,
    std::size_t count) {
    const std::size_t index = static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) return;

    const std::uint64_t nonce = first_nonce + index;
    std::uint8_t first_pass[32];
    std::uint8_t mixed[32];

    blake3_header_pipeline(previous_header, timestamp, nonce, first_pass);

    std::uint32_t hash_mod = 0;
    #pragma unroll
    for (int i = 0; i < 8; ++i) hash_mod ^= load_be32_pipeline(first_pass + i * 4);

    const double nonce_mod = static_cast<double>(nonce & 0xffU);
    double sw = 0.0;
    #pragma unroll 1
    for (int pair = 0; pair < 32; ++pair) {
        const double even_sum = calculate_matrix_row(
            pair * 2, first_pass, hash_mod, nonce_mod, sw);
        const double odd_sum = calculate_matrix_row(
            pair * 2 + 1, first_pass, hash_mod, nonce_mod, sw);
        const std::uint64_t combined = static_cast<std::uint64_t>(even_sum) +
                                       static_cast<std::uint64_t>(odd_sum);
        mixed[pair] = first_pass[pair] ^ static_cast<std::uint8_t>(combined & 0xffU);
    }

    blake3_32_pipeline(mixed, hashes + index * kHashSize);
}

} // namespace

std::vector<std::uint8_t> cuda_pow_hashes_tuned(
    int device_index,
    const crypto::HoohashMatrix& matrix,
    std::span<const std::uint8_t, 32> previous_header,
    std::uint64_t timestamp,
    std::uint64_t first_nonce,
    std::size_t nonce_count,
    unsigned int threads_per_block) {
    if (nonce_count == 0) return {};
    if (threads_per_block == 0 || threads_per_block > 1024 ||
        (threads_per_block % 32U) != 0U) {
        throw std::invalid_argument("threads_per_block must be a warp multiple from 32 to 1024");
    }

    check_cuda_pipeline(cudaSetDevice(device_index), "cudaSetDevice(pipeline)");
    check_cuda_pipeline(
        cudaMemcpyToSymbol(
            kPipelineMatrix,
            matrix.data()->data(),
            kMatrixElements * sizeof(double),
            0,
            cudaMemcpyHostToDevice),
        "cudaMemcpyToSymbol(pipeline matrix)");

    std::uint8_t* device_header = nullptr;
    std::uint8_t* device_hashes = nullptr;
    const std::size_t output_bytes = nonce_count * kHashSize;

    check_cuda_pipeline(cudaMalloc(reinterpret_cast<void**>(&device_header), 32),
                        "cudaMalloc(pipeline header)");
    try {
        check_cuda_pipeline(cudaMalloc(reinterpret_cast<void**>(&device_hashes), output_bytes),
                            "cudaMalloc(pipeline hashes)");
        check_cuda_pipeline(cudaMemcpy(device_header, previous_header.data(), 32,
                                       cudaMemcpyHostToDevice), "cudaMemcpy(pipeline header)");

        const unsigned int blocks = static_cast<unsigned int>(
            (nonce_count + threads_per_block - 1U) / threads_per_block);
        pow_pipeline_kernel<<<blocks, threads_per_block>>>(
            device_header, timestamp, first_nonce, device_hashes, nonce_count);
        check_cuda_pipeline(cudaGetLastError(), "pow_pipeline_kernel launch");
        check_cuda_pipeline(cudaDeviceSynchronize(), "pow_pipeline_kernel synchronize");

        std::vector<std::uint8_t> output(output_bytes);
        check_cuda_pipeline(cudaMemcpy(output.data(), device_hashes, output_bytes,
                                       cudaMemcpyDeviceToHost), "cudaMemcpy(pipeline hashes)");
        cudaFree(device_hashes);
        cudaFree(device_header);
        return output;
    } catch (...) {
        if (device_hashes != nullptr) cudaFree(device_hashes);
        if (device_header != nullptr) cudaFree(device_header);
        throw;
    }
}

std::vector<std::uint8_t> cuda_pow_hashes(
    int device_index,
    const crypto::HoohashMatrix& matrix,
    std::span<const std::uint8_t, 32> previous_header,
    std::uint64_t timestamp,
    std::uint64_t first_nonce,
    std::size_t nonce_count) {
    return cuda_pow_hashes_tuned(
        device_index, matrix, previous_header, timestamp, first_nonce, nonce_count, 64U);
}

} // namespace pepepow
