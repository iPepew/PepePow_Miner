#pragma once

#include "pepepow/core/types.hpp"

#include <optional>
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
        const Hash256& target) = 0;
};

class CpuReferenceBackend final : public MiningBackend {
public:
    [[nodiscard]] std::string_view name() const noexcept override;
    [[nodiscard]] std::vector<DeviceInfo> enumerate_devices() const override;
    [[nodiscard]] std::optional<ShareCandidate> search(
        const MiningJob& job,
        SearchRange range,
        const Hash256& target) override;
};

} // namespace pepepow
