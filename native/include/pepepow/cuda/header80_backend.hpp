#pragma once

#include "pepepow/core/backend.hpp"

namespace pepepow {

struct Header80CudaDiagnostics {
    Hash256 first_pass{};
    Hash256 mixed{};
    Hash256 final_hash{};
};

class Header80CudaBackend final : public MiningBackend {
public:
    explicit Header80CudaBackend(int device_index = 0);

    [[nodiscard]] std::string_view name() const noexcept override;
    [[nodiscard]] std::vector<DeviceInfo> enumerate_devices() const override;
    [[nodiscard]] std::optional<ShareCandidate> search(
        const MiningJob& job,
        SearchRange range,
        std::span<const std::uint8_t, 32> target) override;

    // Runs exactly one nonce through the CUDA HooHashV110 pipeline and captures
    // the three consensus-critical stages. Used only by the startup KAT so a
    // hardware mismatch can be localized without allowing invalid pool shares.
    [[nodiscard]] Header80CudaDiagnostics diagnose(
        const MiningJob& job,
        std::uint32_t nonce);

private:
    int device_index_{0};
};

} // namespace pepepow
