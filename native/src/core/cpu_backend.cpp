#include "pepepow/core/backend.hpp"

#include <optional>
#include <span>
#include <string_view>
#include <vector>

namespace pepepow {

std::string_view CpuReferenceBackend::name() const noexcept {
    return "cpu-reference";
}

std::vector<DeviceInfo> CpuReferenceBackend::enumerate_devices() const {
    return {{0, "Host CPU", 0, 0, 0}};
}

std::optional<ShareCandidate> CpuReferenceBackend::search(
    const MiningJob&,
    SearchRange,
    std::span<const std::uint8_t, 32>) {
    // The real HooHash V110 reference implementation will replace this
    // deliberate no-result scaffold after test vectors are imported.
    return std::nullopt;
}

} // namespace pepepow
