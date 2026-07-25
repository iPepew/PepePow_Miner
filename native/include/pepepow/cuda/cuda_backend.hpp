#pragma once

#include "pepepow/core/backend.hpp"
#include "pepepow/crypto/hoohash_reference.hpp"

#include <cstddef>
#include <cstdint>
#include <span>
#include <vector>

namespace pepepow {

class CudaBackend final : public MiningBackend {
public:
    explicit CudaBackend(int device_index = 0);

    [[nodiscard]] std::string_view name() const noexcept override;
    [[nodiscard]] std::vector<DeviceInfo> enumerate_devices() const override;
    [[nodiscard]] std::optional<ShareCandidate> search(
        const MiningJob& job,
        SearchRange range,
        std::span<const std::uint8_t, 32> target) override;

    [[nodiscard]] int device_index() const noexcept { return device_index_; }

private:
    int device_index_{0};
};

[[nodiscard]] std::vector<std::uint8_t> cuda_build_pow_inputs(
    int device_index,
    std::span<const std::uint8_t, 32> previous_header,
    std::uint64_t timestamp,
    std::uint64_t first_nonce,
    std::size_t nonce_count);

[[nodiscard]] std::vector<std::uint8_t> cuda_first_pass_hashes(
    int device_index,
    std::span<const std::uint8_t, 32> previous_header,
    std::uint64_t timestamp,
    std::uint64_t first_nonce,
    std::size_t nonce_count);

[[nodiscard]] std::vector<std::uint8_t> cuda_hoohash_matrix_mixes(
    int device_index,
    const crypto::HoohashMatrix& matrix,
    std::span<const std::uint8_t> first_pass_hashes,
    std::uint64_t first_nonce,
    std::size_t nonce_count);

// Correctness-first fused path: first BLAKE3, FP64 HooHash matrix mix and final
// BLAKE3 are executed in one CUDA kernel. The CPU-generated matrix is uploaded
// once per call. The result contains nonce_count adjacent 32-byte PoW hashes.
[[nodiscard]] std::vector<std::uint8_t> cuda_pow_hashes(
    int device_index,
    const crypto::HoohashMatrix& matrix,
    std::span<const std::uint8_t, 32> previous_header,
    std::uint64_t timestamp,
    std::uint64_t first_nonce,
    std::size_t nonce_count);

// Benchmark/tuning entry point. threads_per_block must be a warp multiple from
// 32 to 1024. Correctness is identical to cuda_pow_hashes.
[[nodiscard]] std::vector<std::uint8_t> cuda_pow_hashes_tuned(
    int device_index,
    const crypto::HoohashMatrix& matrix,
    std::span<const std::uint8_t, 32> previous_header,
    std::uint64_t timestamp,
    std::uint64_t first_nonce,
    std::size_t nonce_count,
    unsigned int threads_per_block);

// Diagnostic counters for warp-specialization and nonlinear-path feasibility.
// A warp step corresponds to one HooHash matrix cell evaluated by all active
// lanes. Nonlinear call counters include every retry performed after NaN/Inf.
struct CudaWarpDivergenceStats {
    std::uint64_t warp_steps{};
    std::uint64_t uniform_nonlinear_steps{};
    std::uint64_t uniform_linear_steps{};
    std::uint64_t divergent_steps{};
    std::uint64_t nonlinear_lanes{};
    std::uint64_t active_lanes{};
    std::uint64_t exp_sincos_calls{};
    std::uint64_t sin_squared_calls{};
    std::uint64_t inverse_sqrt_calls{};
    std::uint64_t invalid_results{};
    std::uint64_t retry_calls{};
    std::uint64_t zero_fallbacks{};
};

// Measures branch divergence and the nonlinear function distribution without
// changing the production hashing path. first_pass_hashes must contain
// nonce_count adjacent 32-byte BLAKE3 hashes.
[[nodiscard]] CudaWarpDivergenceStats cuda_measure_warp_divergence(
    int device_index,
    const crypto::HoohashMatrix& matrix,
    std::span<const std::uint8_t> first_pass_hashes,
    std::uint64_t first_nonce,
    std::size_t nonce_count,
    unsigned int threads_per_block = 128U);

} // namespace pepepow
