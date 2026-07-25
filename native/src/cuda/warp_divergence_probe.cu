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

constexpr std::size_t kProbeHashSize = 32;
constexpr std::size_t kProbeMatrixElements = 64 * 64;
constexpr double kProbePi = 3.14159265358979323846;
constexpr double kProbeTransformMultiplier = 0.000001;

struct DeviceWarpProbeCounters {
    unsigned long long warp_steps;
    unsigned long long uniform_nonlinear_steps;
    unsigned long long uniform_linear_steps;
    unsigned long long divergent_steps;
    unsigned long long nonlinear_lanes;
    unsigned long long active_lanes;
    unsigned long long exp_sincos_calls;
    unsigned long long sin_squared_calls;
    unsigned long long inverse_sqrt_calls;
    unsigned long long invalid_results;
    unsigned long long retry_calls;
    unsigned long long zero_fallbacks;
};

struct ThreadNonlinearCounters {
    unsigned long long exp_sincos_calls{0};
    unsigned long long sin_squared_calls{0};
    unsigned long long inverse_sqrt_calls{0};
    unsigned long long invalid_results{0};
    unsigned long long retry_calls{0};
    unsigned long long zero_fallbacks{0};
};

void check_cuda_probe(cudaError_t status, const char* operation) {
    if (status != cudaSuccess) {
        throw std::runtime_error(std::string(operation) + ": " + cudaGetErrorString(status));
    }
}

__device__ __forceinline__ double nonlinear_probe(
    double x,
    ThreadNonlinearCounters& counters) {
    const double one_base = x * kProbeTransformMultiplier / 8.0;
    const double two_base = x * kProbeTransformMultiplier / 4.0;
    const double one = one_base - floor(one_base);
    const double two = two_base - floor(two_base);

    double y;
    if (two < 0.25) y = x + 1.0 + two;
    else if (two < 0.50) y = x - 1.0 - two;
    else if (two < 0.75) y = x * (1.0 + two);
    else y = x / (1.0 + two);

    if (one < 0.33) {
        ++counters.exp_sincos_calls;
        double sine;
        double cosine;
        sincos(y, &sine, &cosine);
        return exp(sine + cosine);
    }
    if (one < 0.66) {
        ++counters.sin_squared_calls;
        if (y == kProbePi / 2.0 || y == 3.0 * kProbePi / 2.0) return 0.0;
        const double sine = sin(y);
        return sine * sine;
    }
    ++counters.inverse_sqrt_calls;
    return 1.0 / sqrt(fabs(y) + 1.0);
}

__device__ __forceinline__ double safe_nonlinear_probe(
    double x,
    ThreadNonlinearCounters& counters) {
    double rounds = 1.0;
    double out = nonlinear_probe(x, counters);
    while (isnan(out) || isinf(out)) {
        ++counters.invalid_results;
        x *= 0.1;
        if (x <= 1e-13) {
            ++counters.zero_fallbacks;
            return 0.0;
        }
        ++counters.retry_calls;
        rounds += 1.0;
        out = nonlinear_probe(x, counters);
    }
    return out * rounds;
}

__device__ __forceinline__ std::uint32_t load_be32_probe(const std::uint8_t* p) {
    return (static_cast<std::uint32_t>(p[0]) << 24U) |
           (static_cast<std::uint32_t>(p[1]) << 16U) |
           (static_cast<std::uint32_t>(p[2]) << 8U) |
           static_cast<std::uint32_t>(p[3]);
}

__global__ void warp_divergence_probe_kernel(
    const double* __restrict__ matrix,
    const std::uint8_t* __restrict__ first_passes,
    std::uint64_t first_nonce,
    std::size_t count,
    DeviceWarpProbeCounters* counters) {
    const std::size_t index = static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    const unsigned int full_mask = __activemask();
    const bool active = index < count;
    const unsigned int active_mask = __ballot_sync(full_mask, active);
    if (!active_mask) return;

    const int lane = static_cast<int>(threadIdx.x & 31U);
    const std::uint8_t* first_pass = active ? first_passes + index * kProbeHashSize : nullptr;

    std::uint32_t hash_mod = 0;
    if (active) {
        #pragma unroll
        for (int i = 0; i < 8; ++i) hash_mod ^= load_be32_probe(first_pass + i * 4);
    }

    const double hash_mod_fp64 = static_cast<double>(hash_mod);
    const double nonce_mod = active ? static_cast<double>((first_nonce + index) & 0xffU) : 0.0;
    double sw = 0.0;
    ThreadNonlinearCounters local{};

    #pragma unroll 1
    for (int row = 0; row < 64; ++row) {
        double sum = 0.0;
        const int row_offset = row * 64;

        #pragma unroll 1
        for (int column = 0; column < 64; ++column) {
            const bool nonlinear = active && sw <= 0.02;
            const unsigned int nonlinear_mask = __ballot_sync(active_mask, nonlinear);

            if (lane == __ffs(static_cast<int>(active_mask)) - 1) {
                atomicAdd(&counters->warp_steps, 1ULL);
                atomicAdd(&counters->active_lanes,
                          static_cast<unsigned long long>(__popc(active_mask)));
                atomicAdd(&counters->nonlinear_lanes,
                          static_cast<unsigned long long>(__popc(nonlinear_mask)));
                if (nonlinear_mask == active_mask) {
                    atomicAdd(&counters->uniform_nonlinear_steps, 1ULL);
                } else if (nonlinear_mask == 0U) {
                    atomicAdd(&counters->uniform_linear_steps, 1ULL);
                } else {
                    atomicAdd(&counters->divergent_steps, 1ULL);
                }
            }

            if (active) {
                const std::uint8_t packed = first_pass[column >> 1];
                const double value = static_cast<double>(
                    (column & 1) == 0 ? packed >> 4U : packed & 0x0fU);
                const double cell = __ldg(matrix + row_offset + column);
                if (nonlinear) {
                    const double x = cell * hash_mod_fp64 * value + nonce_mod;
                    sum += safe_nonlinear_probe(x, local) * value * 1234.0;
                } else {
                    sum += cell * 0.0001 * value;
                }
                sw = sum / 1024.0 - floor(sum / 1024.0);
            }
        }
    }

    if (active) {
        atomicAdd(&counters->exp_sincos_calls, local.exp_sincos_calls);
        atomicAdd(&counters->sin_squared_calls, local.sin_squared_calls);
        atomicAdd(&counters->inverse_sqrt_calls, local.inverse_sqrt_calls);
        atomicAdd(&counters->invalid_results, local.invalid_results);
        atomicAdd(&counters->retry_calls, local.retry_calls);
        atomicAdd(&counters->zero_fallbacks, local.zero_fallbacks);
    }
}

} // namespace

CudaWarpDivergenceStats cuda_measure_warp_divergence(
    int device_index,
    const crypto::HoohashMatrix& matrix,
    std::span<const std::uint8_t> first_pass_hashes,
    std::uint64_t first_nonce,
    std::size_t nonce_count,
    unsigned int threads_per_block) {
    if (nonce_count == 0) return {};
    if (first_pass_hashes.size() != nonce_count * kProbeHashSize) {
        throw std::invalid_argument("first_pass_hashes size does not match nonce_count");
    }
    if (threads_per_block == 0 || threads_per_block > 1024 ||
        (threads_per_block % 32U) != 0U) {
        throw std::invalid_argument("threads_per_block must be a warp multiple from 32 to 1024");
    }

    check_cuda_probe(cudaSetDevice(device_index), "cudaSetDevice(warp probe)");

    double* device_matrix = nullptr;
    std::uint8_t* device_first_passes = nullptr;
    DeviceWarpProbeCounters* device_counters = nullptr;
    const std::size_t matrix_bytes = kProbeMatrixElements * sizeof(double);
    const std::size_t input_bytes = first_pass_hashes.size();

    check_cuda_probe(
        cudaMalloc(reinterpret_cast<void**>(&device_matrix), matrix_bytes),
        "cudaMalloc(warp probe matrix)");
    try {
        check_cuda_probe(
            cudaMalloc(reinterpret_cast<void**>(&device_first_passes), input_bytes),
            "cudaMalloc(warp probe first passes)");
        check_cuda_probe(
            cudaMalloc(reinterpret_cast<void**>(&device_counters), sizeof(DeviceWarpProbeCounters)),
            "cudaMalloc(warp probe counters)");
        check_cuda_probe(
            cudaMemcpy(device_matrix, matrix.data()->data(), matrix_bytes,
                       cudaMemcpyHostToDevice),
            "cudaMemcpy(warp probe matrix)");
        check_cuda_probe(
            cudaMemcpy(device_first_passes, first_pass_hashes.data(), input_bytes,
                       cudaMemcpyHostToDevice),
            "cudaMemcpy(warp probe first passes)");
        check_cuda_probe(
            cudaMemset(device_counters, 0, sizeof(DeviceWarpProbeCounters)),
            "cudaMemset(warp probe counters)");

        const unsigned int blocks = static_cast<unsigned int>(
            (nonce_count + threads_per_block - 1U) / threads_per_block);
        warp_divergence_probe_kernel<<<blocks, threads_per_block>>>(
            device_matrix, device_first_passes, first_nonce, nonce_count, device_counters);
        check_cuda_probe(cudaGetLastError(), "warp_divergence_probe_kernel launch");
        check_cuda_probe(cudaDeviceSynchronize(), "warp_divergence_probe_kernel synchronize");

        DeviceWarpProbeCounters host{};
        check_cuda_probe(
            cudaMemcpy(&host, device_counters, sizeof(host), cudaMemcpyDeviceToHost),
            "cudaMemcpy(warp probe counters)");

        cudaFree(device_counters);
        cudaFree(device_first_passes);
        cudaFree(device_matrix);
        return CudaWarpDivergenceStats{
            host.warp_steps,
            host.uniform_nonlinear_steps,
            host.uniform_linear_steps,
            host.divergent_steps,
            host.nonlinear_lanes,
            host.active_lanes,
            host.exp_sincos_calls,
            host.sin_squared_calls,
            host.inverse_sqrt_calls,
            host.invalid_results,
            host.retry_calls,
            host.zero_fallbacks};
    } catch (...) {
        if (device_counters != nullptr) cudaFree(device_counters);
        if (device_first_passes != nullptr) cudaFree(device_first_passes);
        if (device_matrix != nullptr) cudaFree(device_matrix);
        throw;
    }
}

} // namespace pepepow
