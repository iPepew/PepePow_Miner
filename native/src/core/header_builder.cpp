#include "pepepow/core/header_builder.hpp"

#include <algorithm>
#include <cstddef>
#include <cstdint>

namespace pepepow {
namespace {

void write_le32(Header80& out, std::size_t offset, std::uint32_t value) noexcept {
    out[offset + 0] = static_cast<std::uint8_t>(value & 0xffU);
    out[offset + 1] = static_cast<std::uint8_t>((value >> 8U) & 0xffU);
    out[offset + 2] = static_cast<std::uint8_t>((value >> 16U) & 0xffU);
    out[offset + 3] = static_cast<std::uint8_t>((value >> 24U) & 0xffU);
}

void write_be32(Header80& out, std::size_t offset, std::uint32_t value) noexcept {
    out[offset + 0] = static_cast<std::uint8_t>((value >> 24U) & 0xffU);
    out[offset + 1] = static_cast<std::uint8_t>((value >> 16U) & 0xffU);
    out[offset + 2] = static_cast<std::uint8_t>((value >> 8U) & 0xffU);
    out[offset + 3] = static_cast<std::uint8_t>(value & 0xffU);
}

} // namespace

Header80 build_header80(const MiningJob& job) noexcept {
    Header80 header{};
    write_le32(header, 0, job.version);
    std::copy(job.previous_hash.begin(), job.previous_hash.end(), header.begin() + 4);
    std::copy(job.merkle_root.begin(), job.merkle_root.end(), header.begin() + 36);
    write_le32(header, 68, job.ntime);
    write_le32(header, 72, job.bits);

    // HooHash V110/PEPEPOW hashes nonce as BE32 inside Header80. Stratum
    // mining.submit remains the conventional little-endian hex representation.
    write_be32(header, 76, job.nonce);
    return header;
}

} // namespace pepepow
