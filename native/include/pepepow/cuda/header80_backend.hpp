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
    ~Header80CudaBackend() override;

    Header80CudaBackend(const Header80CudaBackend&) = delete;
    Header80CudaBackend& operator=(const Header80CudaBackend&) = delete;
    Header80CudaBackend(Header80CudaBackend&&) = delete;
    Header80CudaBackend& operator=(Header80CudaBackend&&) = delete;

    [[nodiscard]] std::string_view name() const noexcept override;
    [[nodiscard]] std::vector<DeviceInfo> enumerate_devices() const override;
    [[nodiscard]] std::optional<ShareCandidate> search(
        const MiningJob& job,
        SearchRange range,
        const Hash256& target) override;

    [[nodiscard]] Header80CudaDiagnostics diagnose(
        const MiningJob& job,
        std::uint32_t nonce);

private:
    void release_device_state() noexcept;
    void ensure_device_state();
    void prepare_job(const Header80& header);
    void prepare_target(const Hash256& target);

    int device_index_{0};
    void* device_header_{nullptr};
    void* device_result_{nullptr};
    Header80 cached_header_{};
    Hash256 cached_target_{};
    bool header_ready_{false};
    bool target_ready_{false};
};

} // namespace pepepow
