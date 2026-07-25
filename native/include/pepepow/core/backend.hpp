#pragma once

#include "pepepow/core/types.hpp"

#include <optional>
#include <span>
#include <string_view>
#include <vector>

namespace pepepow {

class MiningBackend {
public:
    virtual ~MiningBackend() = default;

    [[nodiscard]] virtual std::string_view name() const noexcept = 0;
    [[nodiscard]] virtual std::vector<DeviceInfo> enumerate_devices() const = 0;
    [[nodiscard]] virtual std::optional<ShareCandidate> search(
        const MiningJob& job,
        SearchRange range,
        std::span<const std::uint8_t, 32> target) = 0;
};

class CpuReferenceBackend final : public MiningBackend {
public:
    [[nodiscard]] std::string_view name() const noexcept override;
    [[nodiscard]] std::vector<DeviceInfo> enumerate_devices() const override;
    [[nodiscard]] std::optional<ShareCandidate> search(
        const MiningJob& job,
        SearchRange range,
        std::span<const std::uint8_t, 32> target) override;
};

} // namespace pepepow
