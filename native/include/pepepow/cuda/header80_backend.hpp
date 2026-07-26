#pragma once

#include "pepepow/core/backend.hpp"

namespace pepepow {

class Header80CudaBackend final : public MiningBackend {
public:
    explicit Header80CudaBackend(int device_index = 0);

    [[nodiscard]] std::string_view name() const noexcept override;
    [[nodiscard]] std::vector<DeviceInfo> enumerate_devices() const override;
    [[nodiscard]] std::optional<ShareCandidate> search(
        const MiningJob& job,
        SearchRange range,
        std::span<const std::uint8_t, 32> target) override;

private:
    int device_index_{0};
};

} // namespace pepepow
