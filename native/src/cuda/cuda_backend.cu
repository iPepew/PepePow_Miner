#include "pepepow/cuda/cuda_backend.hpp"

#include <cuda_runtime.h>

#include <cstddef>
#include <cstdint>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace pepepow {
namespace {

constexpr std::size_t kPowInputSize = 80;
constexpr std::size_t kHashSize = 32;
constexpr std::uint32_t kChunkStart = 1U;
constexpr std::uint32_t kChunkEnd = 2U;
constexpr std::uint32_t kRoot = 8U;

__device__ __constant__ std::uint32_t kBlake3Iv[8] = {
    0x6A09E667U, 0xBB67AE85U, 0x3C6EF372U, 0xA54FF53AU,
    0x510E527FU, 0x9B05688CU, 0x1F83D9ABU, 0x5BE0CD19U};

__device__ __constant__ std::uint8_t kMessageSchedule[7][16] = {
    {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
    {2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8},
    {3, 4, 10, 12, 13, 2, 7, 14, 6, 5, 9, 0, 11, 15, 8, 1},
    {10, 7, 12, 9, 14, 3, 13, 15, 4, 0, 11, 2, 5, 8, 1, 6},
    {12, 13, 9, 11, 15, 10, 14, 8, 7, 2, 5, 3, 0, 1, 6, 4},
    {9, 14, 11, 5, 8, 12, 15, 1, 13, 3, 0, 10, 2, 6, 4, 7},
    {11, 15, 5, 0, 1, 9, 8, 6, 14, 10, 2, 12, 3, 4, 7, 13}};

void check_cuda(cudaError_t status, const char* operation) {
    if (status != cudaSuccess) {
        throw std::runtime_error(std::string(operation) + ": " + cudaGetErrorString(status));
    }
}

__device__ __forceinline__ std::uint32_t rotr32(std::uint32_t value, int bits) {
    return __funnelshift_r(value, value, bits);
}

__device__ __forceinline__ void g(
    std::uint32_t& a,
    std::uint32_t& b,
    std::uint32_t& c,
    std::uint32_t& d,
    std::uint32_t mx,
    std::uint32_t my) {
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
    const std::uint32_t cv[8],
    const std::uint32_t block[16],
    std::uint64_t counter,
    std::uint32_t block_len,
    std::uint32_t flags,
    std::uint32_t out[16]) {
    std::uint32_t v[16];
    #pragma unroll
    for (int i = 0; i < 8; ++i) v[i] = cv[i];
    v[8] = kBlake3Iv[0];
    v[9] = kBlake3Iv[1];
    v[10] = kBlake3Iv[2];
    v[11] = kBlake3Iv[3];
    v[12] = static_cast<std::uint32_t>(counter);
    v[13] = static_cast<std::uint32_t>(counter >> 32U);
    v[14] = block_len;
    v[15] = flags;

    #pragma unroll
    for (int round = 0; round < 7; ++round) {
        const std::uint8_t* s = kMessageSchedule[round];
        g(v[0], v[4], v[8], v[12], block[s[0]], block[s[1]]);
        g(v[1], v[5], v[9], v[13], block[s[2]], block[s[3]]);
        g(v[2], v[6], v[10], v[14], block[s[4]], block[s[5]]);
        g(v[3], v[7], v[11], v[15], block[s[6]], block[s[7]]);
        g(v[0], v[5], v[10], v[15], block[s[8]], block[s[9]]);
        g(v[1], v[6], v[11], v[12], block[s[10]], block[s[11]]);
        g(v[2], v[7], v[8], v[13], block[s[12]], block[s[13]]);
        g(v[3], v[4], v[9], v[14], block[s[14]], block[s[15]]);
    }

    #pragma unroll
    for (int i = 0; i < 8; ++i) {
        out[i] = v[i] ^ v[i + 8];
        out[i + 8] = v[i + 8] ^ cv[i];
    }
}

__device__ __forceinline__ std::uint32_t load_le32(const std::uint8_t* src) {
    return static_cast<std::uint32_t>(src[0]) |
           (static_cast<std::uint32_t>(src[1]) << 8U) |
           (static_cast<std::uint32_t>(src[2]) << 16U) |
           (static_cast<std::uint32_t>(src[3]) << 24U);
}

__device__ __forceinline__ void store_le32(std::uint8_t* dst, std::uint32_t value) {
    dst[0] = static_cast<std::uint8_t>(value);
    dst[1] = static_cast<std::uint8_t>(value >> 8U);
    dst[2] = static_cast<std::uint8_t>(value >> 16U);
    dst[3] = static_cast<std::uint8_t>(value >> 24U);
}

__device__ void store_le64(std::uint8_t* dst, std::uint64_t value) {
    #pragma unroll
    for (int i = 0; i < 8; ++i) {
        dst[i] = static_cast<std::uint8_t>(value >> (i * 8));
    }
}

__device__ void blake3_hash_80(const std::uint8_t input[80], std::uint8_t output[32]) {
    std::uint32_t cv[8];
    std::uint32_t block[16];
    std::uint32_t compressed[16];

    #pragma unroll
    for (int i = 0; i < 8; ++i) cv[i] = kBlake3Iv[i];
    #pragma unroll
    for (int i = 0; i < 16; ++i) block[i] = load_le32(input + i * 4);
    compress(cv, block, 0, 64, kChunkStart, compressed);
    #pragma unroll
    for (int i = 0; i < 8; ++i) cv[i] = compressed[i];

    #pragma unroll
    for (int i = 0; i < 16; ++i) block[i] = 0;
    #pragma unroll
    for (int i = 0; i < 4; ++i) block[i] = load_le32(input + 64 + i * 4);
    compress(cv, block, 0, 16, kChunkEnd | kRoot, compressed);
    #pragma unroll
    for (int i = 0; i < 8; ++i) store_le32(output + i * 4, compressed[i]);
}

__global__ void build_pow_inputs_kernel(
    const std::uint8_t* previous_header,
    std::uint64_t timestamp,
    std::uint64_t first_nonce,
    std::uint8_t* outputs,
    std::size_t count) {
    const std::size_t index = static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) return;

    std::uint8_t* out = outputs + index * kPowInputSize;
    #pragma unroll
    for (int i = 0; i < 32; ++i) out[i] = previous_header[i];
    store_le64(out + 32, timestamp);
    #pragma unroll
    for (int i = 40; i < 72; ++i) out[i] = 0;
    store_le64(out + 72, first_nonce + index);
}

__global__ void first_pass_kernel(
    const std::uint8_t* previous_header,
    std::uint64_t timestamp,
    std::uint64_t first_nonce,
    std::uint8_t* hashes,
    std::size_t count) {
    const std::size_t index = static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) return;

    std::uint8_t input[kPowInputSize];
    #pragma unroll
    for (int i = 0; i < 32; ++i) input[i] = previous_header[i];
    store_le64(input + 32, timestamp);
    #pragma unroll
    for (int i = 40; i < 72; ++i) input[i] = 0;
    store_le64(input + 72, first_nonce + index);
    blake3_hash_80(input, hashes + index * kHashSize);
}

std::uint8_t* copy_header_to_device(std::span<const std::uint8_t, 32> previous_header) {
    std::uint8_t* device_header = nullptr;
    check_cuda(cudaMalloc(reinterpret_cast<void**>(&device_header), 32), "cudaMalloc(previous_header)");
    try {
        check_cuda(cudaMemcpy(device_header, previous_header.data(), 32, cudaMemcpyHostToDevice),
                   "cudaMemcpy(previous_header)");
        return device_header;
    } catch (...) {
        cudaFree(device_header);
        throw;
    }
}

} // namespace

CudaBackend::CudaBackend(int device_index) : device_index_(device_index) {}

std::string_view CudaBackend::name() const noexcept { return "cuda"; }

std::vector<DeviceInfo> CudaBackend::enumerate_devices() const {
    int count = 0;
    check_cuda(cudaGetDeviceCount(&count), "cudaGetDeviceCount");
    std::vector<DeviceInfo> devices;
    devices.reserve(static_cast<std::size_t>(count));
    for (int index = 0; index < count; ++index) {
        cudaDeviceProp properties{};
        check_cuda(cudaGetDeviceProperties(&properties, index), "cudaGetDeviceProperties");
        devices.push_back(DeviceInfo{
            index,
            properties.name,
            properties.major,
            properties.minor,
            properties.totalGlobalMem});
    }
    return devices;
}

std::optional<ShareCandidate> CudaBackend::search(
    const MiningJob&,
    SearchRange,
    std::span<const std::uint8_t, 32>) {
    return std::nullopt;
}

std::vector<std::uint8_t> cuda_build_pow_inputs(
    int device_index,
    std::span<const std::uint8_t, 32> previous_header,
    std::uint64_t timestamp,
    std::uint64_t first_nonce,
    std::size_t nonce_count) {
    if (nonce_count == 0) return {};
    check_cuda(cudaSetDevice(device_index), "cudaSetDevice");

    std::uint8_t* device_header = copy_header_to_device(previous_header);
    std::uint8_t* device_outputs = nullptr;
    const std::size_t output_bytes = nonce_count * kPowInputSize;
    try {
        check_cuda(cudaMalloc(reinterpret_cast<void**>(&device_outputs), output_bytes), "cudaMalloc(outputs)");
        constexpr unsigned int threads = 256;
        const unsigned int blocks = static_cast<unsigned int>((nonce_count + threads - 1) / threads);
        build_pow_inputs_kernel<<<blocks, threads>>>(
            device_header, timestamp, first_nonce, device_outputs, nonce_count);
        check_cuda(cudaGetLastError(), "build_pow_inputs_kernel launch");
        check_cuda(cudaDeviceSynchronize(), "build_pow_inputs_kernel synchronize");

        std::vector<std::uint8_t> outputs(output_bytes);
        check_cuda(cudaMemcpy(outputs.data(), device_outputs, output_bytes, cudaMemcpyDeviceToHost),
                   "cudaMemcpy(outputs)");
        cudaFree(device_outputs);
        cudaFree(device_header);
        return outputs;
    } catch (...) {
        if (device_outputs != nullptr) cudaFree(device_outputs);
        cudaFree(device_header);
        throw;
    }
}

std::vector<std::uint8_t> cuda_first_pass_hashes(
    int device_index,
    std::span<const std::uint8_t, 32> previous_header,
    std::uint64_t timestamp,
    std::uint64_t first_nonce,
    std::size_t nonce_count) {
    if (nonce_count == 0) return {};
    check_cuda(cudaSetDevice(device_index), "cudaSetDevice");

    std::uint8_t* device_header = copy_header_to_device(previous_header);
    std::uint8_t* device_hashes = nullptr;
    const std::size_t output_bytes = nonce_count * kHashSize;
    try {
        check_cuda(cudaMalloc(reinterpret_cast<void**>(&device_hashes), output_bytes), "cudaMalloc(first_pass_hashes)");
        constexpr unsigned int threads = 256;
        const unsigned int blocks = static_cast<unsigned int>((nonce_count + threads - 1) / threads);
        first_pass_kernel<<<blocks, threads>>>(
            device_header, timestamp, first_nonce, device_hashes, nonce_count);
        check_cuda(cudaGetLastError(), "first_pass_kernel launch");
        check_cuda(cudaDeviceSynchronize(), "first_pass_kernel synchronize");

        std::vector<std::uint8_t> hashes(output_bytes);
        check_cuda(cudaMemcpy(hashes.data(), device_hashes, output_bytes, cudaMemcpyDeviceToHost),
                   "cudaMemcpy(first_pass_hashes)");
        cudaFree(device_hashes);
        cudaFree(device_header);
        return hashes;
    } catch (...) {
        if (device_hashes != nullptr) cudaFree(device_hashes);
        cudaFree(device_header);
        throw;
    }
}

} // namespace pepepow
