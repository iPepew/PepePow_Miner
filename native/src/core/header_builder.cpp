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
    // version/ntime/bits are parsed directly from the Stratum hex words. Writing
    // those integers little-endian reproduces ccminer's le32dec + be32enc path.
    write_le32(header, 0, job.version);
    std::copy(job.previous_hash.begin(), job.previous_hash.end(), header.begin() + 4);
    std::copy(job.merkle_root.begin(), job.merkle_root.end(), header.begin() + 36);
    write_le32(header, 68, job.ntime);
    write_le32(header, 72, job.bits);

    // The scan nonce is a host numeric value, not a Stratum hex word. HooHashV110
    // serializes it big-endian into bytes 76..79 of the canonical 80-byte header.
    write_be32(header, 76, job.nonce);
    return header;
}

} // namespace pepepow
