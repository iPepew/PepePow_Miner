#include "pepepow/cuda/header80_backend.hpp"

#include "pepepow/core/header_builder.hpp"
#include "pepepow/crypto/hoohash_reference.hpp"
#include "pepepow/mining/target.hpp"

#include <cuda_runtime.h>

#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace pepepow {
namespace {

constexpr std::size_t kHashSize = 32;
constexpr std::size_t kHeaderSize = 80;
constexpr std::size_t kMatrixElements = 64 * 64;
constexpr double kPi = 3.14159265358979323846;
constexpr double kTransformMultiplier = 0.000001;
constexpr std::uint32_t kChunkStart = 1U;
constexpr std::uint32_t kChunkEnd = 2U;
constexpr std::uint32_t kRoot = 8U;

__device__ __constant__ double kHeader80Matrix[kMatrixElements];
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

void check_cuda_header80(cudaError_t status, const char* operation) {
    if (status != cudaSuccess) {
        throw std::runtime_error(std::string(operation) + ": " + cudaGetErrorString(status));
    }
}

__device__ __forceinline__ std::uint32_t rotr32(std::uint32_t value, int bits) {
    return __funnelshift_r(value, value, bits);
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

__device__ void compress(
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

__device__ __forceinline__ std::uint32_t load_le32(const std::uint8_t* p) {
    return static_cast<std::uint32_t>(p[0]) |
           (static_cast<std::uint32_t>(p[1]) << 8U) |
           (static_cast<std::uint32_t>(p[2]) << 16U) |
           (static_cast<std::uint32_t>(p[3]) << 24U);
}

__device__ __forceinline__ std::uint32_t load_be32(const std::uint8_t* p) {
    return (static_cast<std::uint32_t>(p[0]) << 24U) |
           (static_cast<std::uint32_t>(p[1]) << 16U) |
           (static_cast<std::uint32_t>(p[2]) << 8U) |
           static_cast<std::uint32_t>(p[3]);
}

__device__ __forceinline__ void store_le32(std::uint8_t* p, std::uint32_t v) {
    p[0] = static_cast<std::uint8_t>(v);
    p[1] = static_cast<std::uint8_t>(v >> 8U);
    p[2] = static_cast<std::uint8_t>(v >> 16U);
    p[3] = static_cast<std::uint8_t>(v >> 24U);
}

__device__ void blake3_80(const std::uint8_t input[80], std::uint8_t output[32]) {
    std::uint32_t cv[8], block[16], compressed[16];
    #pragma unroll
    for (int i = 0; i < 8; ++i) cv[i] = kHeader80Iv[i];
    #pragma unroll
    for (int i = 0; i < 16; ++i) block[i] = load_le32(input + i * 4);
    compress(cv, block, 64, kChunkStart, compressed);
    #pragma unroll
    for (int i = 0; i < 8; ++i) cv[i] = compressed[i];
    #pragma unroll
    for (int i = 0; i < 16; ++i) block[i] = 0;
    #pragma unroll
    for (int i = 0; i < 4; ++i) block[i] = load_le32(input + 64 + i * 4);
    compress(cv, block, 16, kChunkEnd | kRoot, compressed);
    #pragma unroll
    for (int i = 0; i < 8; ++i) store_le32(output + i * 4, compressed[i]);
}

__device__ void blake3_32(const std::uint8_t input[32], std::uint8_t output[32]) {
    std::uint32_t cv[8], block[16], compressed[16];
    #pragma unroll
    for (int i = 0; i < 8; ++i) cv[i] = kHeader80Iv[i];
    #pragma unroll
    for (int i = 0; i < 16; ++i) block[i] = 0;
    #pragma unroll
    for (int i = 0; i < 8; ++i) block[i] = load_le32(input + i * 4);
    compress(cv, block, 32, kChunkStart | kChunkEnd | kRoot, compressed);
    #pragma unroll
    for (int i = 0; i < 8; ++i) store_le32(output + i * 4, compressed[i]);
}

__device__ __forceinline__ double nonlinear(double x) {
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
        double sine, cosine;
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

__device__ __forceinline__ void accumulate(
    double cell, double value, double hash_mod, double nonce_mod,
    double& sum, double& sw) {
    if (sw <= 0.02) {
        const double x = cell * hash_mod * value + nonce_mod;
        sum += safe_nonlinear(x) * value * 1234.0;
    } else {
        sum += cell * 0.0001 * value;
    }
    sw = sum / 1024.0 - floor(sum / 1024.0);
}

__device__ double matrix_row(
    int row, const std::uint8_t first_pass[32], std::uint32_t hash_mod,
    double nonce_mod, double& sw) {
    double sum = 0.0;
    const double hash_mod_fp64 = static_cast<double>(hash_mod);
    const int row_offset = row * 64;
    #pragma unroll 1
    for (int byte_index = 0; byte_index < 32; ++byte_index) {
        const std::uint8_t packed = first_pass[byte_index];
        const int column = byte_index * 2;
        accumulate(kHeader80Matrix[row_offset + column],
                   static_cast<double>(packed >> 4U), hash_mod_fp64, nonce_mod, sum, sw);
        accumulate(kHeader80Matrix[row_offset + column + 1],
                   static_cast<double>(packed & 0x0fU), hash_mod_fp64, nonce_mod, sum, sw);
    }
    return sum;
}

__global__ void header80_pow_kernel(
    const std::uint8_t* __restrict__ base_header,
    std::uint32_t first_nonce,
    std::uint8_t* __restrict__ hashes,
    std::size_t count) {
    const std::size_t index = static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) return;

    const std::uint32_t nonce = first_nonce + static_cast<std::uint32_t>(index);
    std::uint8_t header[kHeaderSize];
    #pragma unroll
    for (int i = 0; i < static_cast<int>(kHeaderSize); ++i) header[i] = base_header[i];
    store_le32(header + 76, nonce);

    std::uint8_t first_pass[32];
    std::uint8_t mixed[32];
    blake3_80(header, first_pass);

    std::uint32_t hash_mod = 0;
    #pragma unroll
    for (int i = 0; i < 8; ++i) hash_mod ^= load_be32(first_pass + i * 4);

    const double nonce_mod = static_cast<double>(nonce & 0xffU);
    double sw = 0.0;
    #pragma unroll 1
    for (int pair = 0; pair < 32; ++pair) {
        const double even_sum = matrix_row(pair * 2, first_pass, hash_mod, nonce_mod, sw);
        const double odd_sum = matrix_row(pair * 2 + 1, first_pass, hash_mod, nonce_mod, sw);
        const std::uint64_t combined = static_cast<std::uint64_t>(even_sum) +
                                       static_cast<std::uint64_t>(odd_sum);
        mixed[pair] = first_pass[pair] ^ static_cast<std::uint8_t>(combined & 0xffU);
    }
    blake3_32(mixed, hashes + index * kHashSize);
}

} // namespace

Header80CudaBackend::Header80CudaBackend(int device_index) : device_index_(device_index) {}

std::string_view Header80CudaBackend::name() const noexcept { return "cuda-header80"; }

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
    base_job.nonce = static_cast<std::uint32_t>(range.begin);
    const Header80 header = build_header80(base_job);
    const crypto::HoohashMatrix matrix = crypto::generate_hoohash_matrix(job.previous_hash);

    check_cuda_header80(cudaSetDevice(device_index_), "cudaSetDevice(header80)");
    check_cuda_header80(
        cudaMemcpyToSymbol(kHeader80Matrix, matrix.data()->data(),
                           kMatrixElements * sizeof(double), 0, cudaMemcpyHostToDevice),
        "cudaMemcpyToSymbol(header80 matrix)");

    std::uint8_t* device_header = nullptr;
    std::uint8_t* device_hashes = nullptr;
    const std::size_t output_bytes = count * kHashSize;
    check_cuda_header80(cudaMalloc(reinterpret_cast<void**>(&device_header), kHeaderSize),
                        "cudaMalloc(header80)");
    try {
        check_cuda_header80(cudaMalloc(reinterpret_cast<void**>(&device_hashes), output_bytes),
                            "cudaMalloc(header80 hashes)");
        check_cuda_header80(cudaMemcpy(device_header, header.data(), kHeaderSize,
                                       cudaMemcpyHostToDevice), "cudaMemcpy(header80)");

        constexpr unsigned int threads = 64U;
        const unsigned int blocks = static_cast<unsigned int>((count + threads - 1U) / threads);
        header80_pow_kernel<<<blocks, threads>>>(
            device_header, static_cast<std::uint32_t>(range.begin), device_hashes, count);
        check_cuda_header80(cudaGetLastError(), "header80_pow_kernel launch");
        check_cuda_header80(cudaDeviceSynchronize(), "header80_pow_kernel synchronize");

        std::vector<std::uint8_t> hashes(output_bytes);
        check_cuda_header80(cudaMemcpy(hashes.data(), device_hashes, output_bytes,
                                       cudaMemcpyDeviceToHost), "cudaMemcpy(header80 hashes)");
        cudaFree(device_hashes);
        cudaFree(device_header);

        mining::Target256 target_array{};
        std::copy(target.begin(), target.end(), target_array.begin());
        for (std::size_t index = 0; index < count; ++index) {
            Hash256 hash{};
            std::copy_n(hashes.begin() + static_cast<std::ptrdiff_t>(index * kHashSize),
                        kHashSize, hash.begin());
            if (mining::hash_meets_target_be(hash, target_array)) {
                return ShareCandidate{job.job_id,
                    static_cast<std::uint32_t>(range.begin + index), hash};
            }
        }
        return std::nullopt;
    } catch (...) {
        if (device_hashes != nullptr) cudaFree(device_hashes);
        if (device_header != nullptr) cudaFree(device_header);
        throw;
    }
}

} // namespace pepepow
