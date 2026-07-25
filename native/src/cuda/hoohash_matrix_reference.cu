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
constexpr std::size_t kMatrixSize = 64;
constexpr std::size_t kMatrixElements = kMatrixSize * kMatrixSize;
constexpr double kPi = 3.14159265358979323846;
constexpr double kTransformMultiplier = 0.000001;

void check_cuda_matrix(cudaError_t status, const char* operation) {
    if (status != cudaSuccess) {
        throw std::runtime_error(std::string(operation) + ": " + cudaGetErrorString(status));
    }
}

__device__ __forceinline__ std::uint32_t load_be32_device(const std::uint8_t* p) {
    return (static_cast<std::uint32_t>(p[0]) << 24U) |
           (static_cast<std::uint32_t>(p[1]) << 16U) |
           (static_cast<std::uint32_t>(p[2]) << 8U) |
           static_cast<std::uint32_t>(p[3]);
}

__device__ __forceinline__ double medium_device(double x) {
    return exp(sin(x) + cos(x));
}

__device__ __forceinline__ double intermediate_device(double x) {
    if (x == kPi / 2.0 || x == 3.0 * kPi / 2.0) return 0.0;
    const double s = sin(x);
    return s * s;
}

__device__ __forceinline__ double high_device(double x) {
    return 1.0 / sqrt(fabs(x) + 1.0);
}

__device__ __forceinline__ double complex_nonlinear_device(double x) {
    const double one_base = x * kTransformMultiplier / 8.0;
    const double two_base = x * kTransformMultiplier / 4.0;
    const double one = one_base - floor(one_base);
    const double two = two_base - floor(two_base);

    double transformed;
    if (two < 0.25) transformed = x + 1.0 + two;
    else if (two < 0.50) transformed = x - 1.0 - two;
    else if (two < 0.75) transformed = x * (1.0 + two);
    else transformed = x / (1.0 + two);

    if (one < 0.33) return medium_device(transformed);
    if (one < 0.66) return intermediate_device(transformed);
    return high_device(transformed);
}

__device__ __forceinline__ double for_complex_device(double x) {
    double rounds = 1.0;
    double out = complex_nonlinear_device(x);
    while (isnan(out) || isinf(out)) {
        x *= 0.1;
        if (x <= 1e-13) return 0.0;
        rounds += 1.0;
        out = complex_nonlinear_device(x);
    }
    return out * rounds;
}

__global__ void hoohash_matrix_mix_kernel(
    const double* matrix,
    const std::uint8_t* first_pass_hashes,
    std::uint64_t first_nonce,
    std::uint8_t* mixed_hashes,
    std::size_t count) {
    const std::size_t index = static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) return;

    const std::uint8_t* first_pass = first_pass_hashes + index * kHashSize;
    std::uint8_t* mixed = mixed_hashes + index * kHashSize;
    std::uint8_t vector[kMatrixSize];
    double product[kMatrixSize];

    std::uint32_t hash_mod = 0;
    #pragma unroll
    for (int i = 0; i < 8; ++i) hash_mod ^= load_be32_device(first_pass + i * 4);

    #pragma unroll
    for (int i = 0; i < 32; ++i) {
        vector[i * 2] = first_pass[i] >> 4U;
        vector[i * 2 + 1] = first_pass[i] & 0x0fU;
    }

    const double nonce_mod = static_cast<double>((first_nonce + index) & 0xffU);
    double sw = 0.0;

    #pragma unroll 1
    for (int row = 0; row < 64; ++row) {
        double sum = 0.0;
        #pragma unroll 1
        for (int column = 0; column < 64; ++column) {
            const double cell = matrix[row * 64 + column];
            const double value = static_cast<double>(vector[column]);
            if (sw <= 0.02) {
                const double input = cell * static_cast<double>(hash_mod) * value + nonce_mod;
                sum += for_complex_device(input) * value * 1234.0;
            } else {
                sum += cell * 0.0001 * value;
            }
            sw = sum / 1024.0 - floor(sum / 1024.0);
        }
        product[row] = sum;
    }

    #pragma unroll
    for (int i = 0; i < 32; ++i) {
        const auto p = static_cast<std::uint64_t>(product[i * 2]) +
                       static_cast<std::uint64_t>(product[i * 2 + 1]);
        mixed[i] = first_pass[i] ^ static_cast<std::uint8_t>(p & 0xffU);
    }
}

} // namespace

std::vector<std::uint8_t> cuda_hoohash_matrix_mixes(
    int device_index,
    const crypto::HoohashMatrix& matrix,
    std::span<const std::uint8_t> first_pass_hashes,
    std::uint64_t first_nonce,
    std::size_t nonce_count) {
    if (nonce_count == 0) return {};
    if (first_pass_hashes.size() != nonce_count * kHashSize) {
        throw std::invalid_argument("first_pass_hashes size does not match nonce_count");
    }

    check_cuda_matrix(cudaSetDevice(device_index), "cudaSetDevice(matrix)");

    double* device_matrix = nullptr;
    std::uint8_t* device_first_passes = nullptr;
    std::uint8_t* device_mixed = nullptr;
    const std::size_t hashes_bytes = nonce_count * kHashSize;

    check_cuda_matrix(cudaMalloc(reinterpret_cast<void**>(&device_matrix),
                                 kMatrixElements * sizeof(double)),
                      "cudaMalloc(matrix)");
    try {
        check_cuda_matrix(cudaMalloc(reinterpret_cast<void**>(&device_first_passes), hashes_bytes),
                          "cudaMalloc(first_passes)");
        check_cuda_matrix(cudaMalloc(reinterpret_cast<void**>(&device_mixed), hashes_bytes),
                          "cudaMalloc(mixed)");
        check_cuda_matrix(cudaMemcpy(device_matrix, matrix.data()->data(),
                                     kMatrixElements * sizeof(double), cudaMemcpyHostToDevice),
                          "cudaMemcpy(matrix)");
        check_cuda_matrix(cudaMemcpy(device_first_passes, first_pass_hashes.data(), hashes_bytes,
                                     cudaMemcpyHostToDevice),
                          "cudaMemcpy(first_passes)");

        constexpr unsigned int threads = 64;
        const unsigned int blocks = static_cast<unsigned int>((nonce_count + threads - 1) / threads);
        hoohash_matrix_mix_kernel<<<blocks, threads>>>(
            device_matrix, device_first_passes, first_nonce, device_mixed, nonce_count);
        check_cuda_matrix(cudaGetLastError(), "hoohash_matrix_mix_kernel launch");
        check_cuda_matrix(cudaDeviceSynchronize(), "hoohash_matrix_mix_kernel synchronize");

        std::vector<std::uint8_t> output(hashes_bytes);
        check_cuda_matrix(cudaMemcpy(output.data(), device_mixed, hashes_bytes, cudaMemcpyDeviceToHost),
                          "cudaMemcpy(mixed)");
        cudaFree(device_mixed);
        cudaFree(device_first_passes);
        cudaFree(device_matrix);
        return output;
    } catch (...) {
        if (device_mixed != nullptr) cudaFree(device_mixed);
        if (device_first_passes != nullptr) cudaFree(device_first_passes);
        cudaFree(device_matrix);
        throw;
    }
}

} // namespace pepepow
