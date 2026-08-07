#pragma once

#include "pepepow/core/backend.hpp"

#include <cstddef>

namespace pepepow {

class Header80CudaBackend final : public MiningBackend {
public:
    explicit Header80CudaBackend(int device_index = 0, unsigned int threads_per_block = 0);
    ~Header80CudaBackend() override;

    Header80CudaBackend(const Header80CudaBackend&) = delete;
    Header80CudaBackend& operator=(const Header80CudaBackend&) = delete;

    [[nodiscard]] std::string_view name() const noexcept override;
    [[nodiscard]] std::vector<DeviceInfo> enumerate_devices() const override;
    [[nodiscard]] std::optional<ShareCandidate> search(
        const MiningJob& job,
        SearchRange range,
        std::span<const std::uint8_t, 32> target) override;

private:
    int device_index_{0};
    unsigned int threads_per_block_{0};
    void* device_result_{nullptr};
    void* device_matrix_{nullptr};
    void* device_scaled_nibble_{nullptr};
    void* device_work_{nullptr};
    std::size_t device_work_capacity_{0};
};

} // namespace pepepow
