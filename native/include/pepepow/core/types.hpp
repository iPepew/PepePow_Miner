#pragma once

#include <array>
#include <cstddef>
#include <cstdint>
#include <string>

namespace pepepow {

using Hash256 = std::array<std::uint8_t, 32>;
using Header80 = std::array<std::uint8_t, 80>;

struct MiningJob {
    std::string job_id;
    std::uint32_t version{0};
    Hash256 previous_hash{};
    Hash256 merkle_root{};
    std::uint32_t ntime{0};
    std::uint32_t bits{0};
    std::uint32_t nonce{0};
};

struct ShareCandidate {
    std::string job_id;
    std::uint32_t nonce{0};
    Hash256 hash{};
};

struct SearchRange {
    std::uint64_t begin{0};
    std::uint64_t count{0};
};

struct DeviceInfo {
    int index{-1};
    std::string name;
    int compute_major{0};
    int compute_minor{0};
    std::size_t global_memory_bytes{0};
};

} // namespace pepepow
