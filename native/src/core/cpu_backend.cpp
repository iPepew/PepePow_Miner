#include "pepepow/core/backend.hpp"

#include "pepepow/core/header_builder.hpp"
#include "pepepow/crypto/pow.hpp"
#include "pepepow/mining/target.hpp"

#include <algorithm>
#include <cstdint>
#include <limits>
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
    const MiningJob& job,
    SearchRange range,
    std::span<const std::uint8_t, 32> target) {
    if (range.count == 0 || range.begin > std::numeric_limits<std::uint32_t>::max()) {
        return std::nullopt;
    }

    mining::Target256 target_value{};
    std::copy(target.begin(), target.end(), target_value.begin());

    const std::uint64_t max_count =
        static_cast<std::uint64_t>(std::numeric_limits<std::uint32_t>::max()) - range.begin + 1U;
    const std::uint64_t count = std::min(range.count, max_count);

    MiningJob candidate_job = job;
    for (std::uint64_t offset = 0; offset < count; ++offset) {
        candidate_job.nonce = static_cast<std::uint32_t>(range.begin + offset);
        const Header80 header = build_header80(candidate_job);
        const Hash256 hash = crypto::calculate_header80_pow(header);
        if (mining::hash_meets_target_be(hash, target_value)) {
            return ShareCandidate{job.job_id, candidate_job.nonce, hash};
        }
    }

    return std::nullopt;
}

} // namespace pepepow
