#include "pepepow/cuda/header80_backend.hpp"

#include "pepepow/core/header_builder.hpp"
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
constexpr int kMatrixSide = 64;
constexpr double kPi = 3.14159265358979323846;
constexpr double kEpsilon = 1e-9;
constexpr double kTransformMultiplier = 0.000001;
constexpr std::uint32_t kChunkStart = 1U;
constexpr std::uint32_t kChunkEnd = 2U;
constexpr std::uint32_t kRoot = 8U;

__device__ double g_matrix[kMatrixSide][kMatrixSide];
__device__ __constant__ std::uint32_t kIv[8] = {
    0x6A09E667U, 0xBB67AE85U, 0x3C6EF372U, 0xA54FF53AU,
    0x510E527FU, 0x9B05688CU, 0x1F83D9ABU, 0x5BE0CD19U};
__device__ __constant__ std::uint8_t kSchedule[7][16] = {
    {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15},
    {2,6,3,10,7,0,4,13,1,11,12,5,9,14,15,8},
    {3,4,10,12,13,2,7,14,6,5,9,0,11,15,8,1},
    {10,7,12,9,14,3,13,15,4,0,11,2,5,8,1,6},
    {12,13,9,11,15,10,14,8,7,2,5,3,0,1,6,4},
    {9,14,11,5,8,12,15,1,13,3,0,10,2,12,3,4,7},
    {11,15,5,0,1,9,8,6,14,10,2,12,3,4,7,13}};

// Correct the sixth row explicitly. Keeping the table literal close to the BLAKE3
// permutation makes CUDA 11.8 and the current backend easy to compare.
__device__ __forceinline__ std::uint8_t schedule_value(int round, int index) {
    if (round == 5) {
        const std::uint8_t row[16] = {9,14,11,5,8,12,15,1,13,3,0,10,2,6,4,7};
        return row[index];
    }
    return kSchedule[round][index];
}

void check_cuda(cudaError_t status, const char* operation) {
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
    for (int i = 0; i < 4; ++i) v[8 + i] = kIv[i];
    v[12] = 0;
    v[13] = 0;
    v[14] = block_len;
    v[15] = flags;

    #pragma unroll
    for (int round = 0; round < 7; ++round) {
        std::uint8_t s[16];
        #pragma unroll
        for (int i = 0; i < 16; ++i) s[i] = schedule_value(round, i);
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

__device__ __forceinline__ std::uint64_t load_le64(const std::uint8_t* p) {
    std::uint64_t value = 0;
    #pragma unroll
    for (int i = 0; i < 8; ++i) value |= static_cast<std::uint64_t>(p[i]) << (i * 8);
    return value;
}

__device__ __forceinline__ void store_le32(std::uint8_t* p, std::uint32_t value) {
    p[0] = static_cast<std::uint8_t>(value);
    p[1] = static_cast<std::uint8_t>(value >> 8U);
    p[2] = static_cast<std::uint8_t>(value >> 16U);
    p[3] = static_cast<std::uint8_t>(value >> 24U);
}

__device__ __forceinline__ void store_be32(std::uint8_t* p, std::uint32_t value) {
    p[0] = static_cast<std::uint8_t>(value >> 24U);
    p[1] = static_cast<std::uint8_t>(value >> 16U);
    p[2] = static_cast<std::uint8_t>(value >> 8U);
    p[3] = static_cast<std::uint8_t>(value);
}

__device__ void blake3_80(const std::uint8_t input[80], std::uint8_t output[32]) {
    std::uint32_t cv[8], block[16], compressed[16];
    #pragma unroll
    for (int i = 0; i < 8; ++i) cv[i] = kIv[i];
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
    for (int i = 0; i < 8; ++i) cv[i] = kIv[i];
    #pragma unroll
    for (int i = 0; i < 16; ++i) block[i] = 0;
    #pragma unroll
    for (int i = 0; i < 8; ++i) block[i] = load_le32(input + i * 4);
    compress(cv, block, 32, kChunkStart | kChunkEnd | kRoot, compressed);
    #pragma unroll
    for (int i = 0; i < 8; ++i) store_le32(output + i * 4, compressed[i]);
}

struct XoshiroState {
    std::uint64_t s0, s1, s2, s3;
};

__device__ __forceinline__ std::uint64_t rotl64(std::uint64_t value, int bits) {
    return (value << bits) | (value >> (64 - bits));
}

__device__ __forceinline__ std::uint64_t xoshiro_next(XoshiroState& state) {
    const std::uint64_t result = rotl64(state.s0 + state.s3, 23) + state.s0;
    const std::uint64_t t = state.s1 << 17;
    state.s2 ^= state.s0;
    state.s3 ^= state.s1;
    state.s1 ^= state.s2;
    state.s0 ^= state.s3;
    state.s2 ^= t;
    state.s3 = rotl64(state.s3, 45);
    return result;
}

__global__ void generate_matrix_kernel(const std::uint8_t* base_header) {
    if (blockIdx.x != 0 || threadIdx.x != 0) return;

    std::uint8_t masked[80];
    #pragma unroll
    for (int i = 0; i < 80; ++i) masked[i] = base_header[i];
    masked[76] = masked[77] = masked[78] = masked[79] = 0;

    std::uint8_t seed[32];
    blake3_80(masked, seed);
    XoshiroState state{load_le64(seed), load_le64(seed + 8), load_le64(seed + 16), load_le64(seed + 24)};

    for (int row = 0; row < 64; ++row) {
        for (int col = 0; col < 64; ++col) {
            const std::uint32_t low = static_cast<std::uint32_t>(xoshiro_next(state) & 0xffffffffULL);
            g_matrix[row][col] = static_cast<double>(low) /
                                 static_cast<double>(0xffffffffU) * 1000000.0;
        }
    }
}

__device__ __forceinline__ double nonlinear(double x) {
    const double one = (x * kTransformMultiplier) / 8.0 -
                       floor((x * kTransformMultiplier) / 8.0);
    const double two = (x * kTransformMultiplier) / 4.0 -
                       floor((x * kTransformMultiplier) / 4.0);

    double y;
    if (two < 0.25) y = x + (1.0 + two);
    else if (two < 0.50) y = x - (1.0 + two);
    else if (two < 0.75) y = x * (1.0 + two);
    else y = x / (1.0 + two);

    if (one < 0.33) {
        double s, c;
        sincos(y, &s, &c);
        return exp(s + c);
    }
    if (one < 0.66) {
        if (fabs(y - kPi / 2.0) < kEpsilon || fabs(y - 3.0 * kPi / 2.0) < kEpsilon) {
            return 0.0;
        }
        const double s = sin(y);
        return s * s;
    }
    return 1.0 / sqrt(fabs(y) + 1.0);
}

__device__ __forceinline__ double safe_nonlinear(double input) {
    double rounds = 1.0;
    const double transformed = nonlinear(input);
    while (isnan(transformed) || isinf(transformed)) {
        input *= 0.1;
        if (input <= 1e-13) return 0.0;
        rounds += 1.0;
    }
    return transformed * rounds;
}

__device__ void matrix_mix(
    const std::uint8_t first_pass[32], std::uint8_t mixed[32], std::uint32_t nonce_le) {
    std::uint8_t vector[64]{};
    double product[64]{};
    std::uint32_t words[8]{};

    #pragma unroll
    for (int i = 0; i < 8; ++i) words[i] = load_be32(first_pass + i * 4);
    const double hash_xor = static_cast<double>(
        words[0] ^ words[1] ^ words[2] ^ words[3] ^ words[4] ^ words[5] ^ words[6] ^ words[7]);
    const double nonce_mod = static_cast<double>(nonce_le & 0xffU);

    #pragma unroll
    for (int i = 0; i < 32; ++i) {
        vector[i * 2] = first_pass[i] >> 4U;
        vector[i * 2 + 1] = first_pass[i] & 0x0fU;
    }

    double sw = 0.0;
    for (int row = 0; row < 64; ++row) {
        for (int col = 0; col < 64; ++col) {
            if (sw <= 0.02) {
                const double input = g_matrix[row][col] * hash_xor *
                                     static_cast<double>(vector[col]) + nonce_mod;
                product[row] += safe_nonlinear(input) *
                                static_cast<double>(vector[col]) * 1234.0;
            } else {
                product[row] += g_matrix[row][col] * 0.0001 *
                                static_cast<double>(vector[col]);
            }
            sw = product[row] / 1024.0 - floor(product[row] / 1024.0);
        }
    }

    #pragma unroll
    for (int i = 0; i < 32; ++i) {
        const std::uint64_t combined = static_cast<std::uint64_t>(product[i * 2]) +
                                       static_cast<std::uint64_t>(product[i * 2 + 1]);
        mixed[i] = first_pass[i] ^ static_cast<std::uint8_t>(combined & 0xffU);
    }
}

template <bool CaptureStages>
__device__ void hash_one(
    const std::uint8_t* base_header,
    std::uint32_t nonce,
    std::uint8_t* final_hash,
    std::uint8_t* capture_first,
    std::uint8_t* capture_mixed) {
    std::uint8_t header[80];
    #pragma unroll
    for (int i = 0; i < 80; ++i) header[i] = base_header[i];
    store_be32(header + 76, nonce);

    std::uint8_t first_pass[32];
    std::uint8_t mixed[32];
    blake3_80(header, first_pass);
    matrix_mix(first_pass, mixed, load_le32(header + 76));
    blake3_32(mixed, final_hash);

    if (CaptureStages) {
        #pragma unroll
        for (int i = 0; i < 32; ++i) {
            capture_first[i] = first_pass[i];
            capture_mixed[i] = mixed[i];
        }
    }
}

__global__ void hash_kernel(
    const std::uint8_t* base_header,
    std::uint32_t first_nonce,
    std::uint8_t* hashes,
    std::size_t count) {
    const std::size_t index = static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) return;
    hash_one<false>(base_header,
                    first_nonce + static_cast<std::uint32_t>(index),
                    hashes + index * 32,
                    nullptr,
                    nullptr);
}

__global__ void diagnostic_kernel(
    const std::uint8_t* base_header,
    std::uint32_t nonce,
    std::uint8_t* first_pass,
    std::uint8_t* mixed,
    std::uint8_t* final_hash) {
    if (blockIdx.x != 0 || threadIdx.x != 0) return;
    hash_one<true>(base_header, nonce, final_hash, first_pass, mixed);
}

Header80 make_header(const MiningJob& job, std::uint32_t nonce) {
    MiningJob base = job;
    base.nonce = nonce;
    return build_header80(base);
}

void prepare_job(int device_index, const Header80& header, std::uint8_t** device_header) {
    check_cuda(cudaSetDevice(device_index), "cudaSetDevice(header80 legacy)");
    check_cuda(cudaMalloc(reinterpret_cast<void**>(device_header), kHeaderSize),
               "cudaMalloc(header80 legacy header)");
    check_cuda(cudaMemcpy(*device_header, header.data(), kHeaderSize, cudaMemcpyHostToDevice),
               "cudaMemcpy(header80 legacy header)");
    generate_matrix_kernel<<<1, 1>>>(*device_header);
    check_cuda(cudaGetLastError(), "generate_matrix_kernel launch");
    check_cuda(cudaDeviceSynchronize(), "generate_matrix_kernel synchronize");
}

} // namespace

Header80CudaBackend::Header80CudaBackend(int device_index) : device_index_(device_index) {}

std::string_view Header80CudaBackend::name() const noexcept {
    return "cuda-header80-legacy";
}

std::vector<DeviceInfo> Header80CudaBackend::enumerate_devices() const {
    int count = 0;
    check_cuda(cudaGetDeviceCount(&count), "cudaGetDeviceCount");
    std::vector<DeviceInfo> devices;
    devices.reserve(static_cast<std::size_t>(count));
    for (int index = 0; index < count; ++index) {
        cudaDeviceProp properties{};
        check_cuda(cudaGetDeviceProperties(&properties, index), "cudaGetDeviceProperties");
        devices.push_back(DeviceInfo{index, properties.name, properties.major,
                                     properties.minor, properties.totalGlobalMem});
    }
    return devices;
}

Header80CudaDiagnostics Header80CudaBackend::diagnose(
    const MiningJob& job,
    std::uint32_t nonce) {
    const Header80 header = make_header(job, nonce);
    std::uint8_t* device_header = nullptr;
    std::uint8_t* device_first = nullptr;
    std::uint8_t* device_mixed = nullptr;
    std::uint8_t* device_final = nullptr;

    prepare_job(device_index_, header, &device_header);
    try {
        check_cuda(cudaMalloc(reinterpret_cast<void**>(&device_first), 32), "cudaMalloc(KAT first)");
        check_cuda(cudaMalloc(reinterpret_cast<void**>(&device_mixed), 32), "cudaMalloc(KAT mixed)");
        check_cuda(cudaMalloc(reinterpret_cast<void**>(&device_final), 32), "cudaMalloc(KAT final)");

        diagnostic_kernel<<<1, 1>>>(device_header, nonce, device_first, device_mixed, device_final);
        check_cuda(cudaGetLastError(), "diagnostic_kernel launch");
        check_cuda(cudaDeviceSynchronize(), "diagnostic_kernel synchronize");

        Header80CudaDiagnostics result{};
        check_cuda(cudaMemcpy(result.first_pass.data(), device_first, 32, cudaMemcpyDeviceToHost),
                   "cudaMemcpy(KAT first)");
        check_cuda(cudaMemcpy(result.mixed.data(), device_mixed, 32, cudaMemcpyDeviceToHost),
                   "cudaMemcpy(KAT mixed)");
        check_cuda(cudaMemcpy(result.final_hash.data(), device_final, 32, cudaMemcpyDeviceToHost),
                   "cudaMemcpy(KAT final)");

        cudaFree(device_final);
        cudaFree(device_mixed);
        cudaFree(device_first);
        cudaFree(device_header);
        return result;
    } catch (...) {
        if (device_final) cudaFree(device_final);
        if (device_mixed) cudaFree(device_mixed);
        if (device_first) cudaFree(device_first);
        if (device_header) cudaFree(device_header);
        throw;
    }
}

std::optional<ShareCandidate> Header80CudaBackend::search(
    const MiningJob& job,
    SearchRange range,
    const Hash256& target) {
    if (range.count == 0 || range.begin > std::numeric_limits<std::uint32_t>::max()) {
        return std::nullopt;
    }

    const std::uint64_t available = 0x100000000ULL - range.begin;
    const std::size_t count = static_cast<std::size_t>(std::min(range.count, available));
    if (count == 0) return std::nullopt;

    const Header80 header = make_header(job, static_cast<std::uint32_t>(range.begin));
    std::uint8_t* device_header = nullptr;
    std::uint8_t* device_hashes = nullptr;
    prepare_job(device_index_, header, &device_header);

    try {
        const std::size_t bytes = count * 32;
        check_cuda(cudaMalloc(reinterpret_cast<void**>(&device_hashes), bytes),
                   "cudaMalloc(header80 legacy hashes)");

        constexpr unsigned int threads = 64U;
        const unsigned int blocks = static_cast<unsigned int>((count + threads - 1U) / threads);
        hash_kernel<<<blocks, threads>>>(device_header,
                                         static_cast<std::uint32_t>(range.begin),
                                         device_hashes,
                                         count);
        check_cuda(cudaGetLastError(), "hash_kernel launch");
        check_cuda(cudaDeviceSynchronize(), "hash_kernel synchronize");

        std::vector<std::uint8_t> hashes(bytes);
        check_cuda(cudaMemcpy(hashes.data(), device_hashes, bytes, cudaMemcpyDeviceToHost),
                   "cudaMemcpy(header80 legacy hashes)");

        cudaFree(device_hashes);
        cudaFree(device_header);
        device_hashes = nullptr;
        device_header = nullptr;

        for (std::size_t index = 0; index < count; ++index) {
            Hash256 hash{};
            std::copy_n(hashes.begin() + static_cast<std::ptrdiff_t>(index * 32), 32, hash.begin());
            if (mining::hash_meets_target_be(hash, target)) {
                return ShareCandidate{job.job_id,
                    static_cast<std::uint32_t>(range.begin + index), hash};
            }
        }
        return std::nullopt;
    } catch (...) {
        if (device_hashes) cudaFree(device_hashes);
        if (device_header) cudaFree(device_header);
        throw;
    }
}

} // namespace pepepow
