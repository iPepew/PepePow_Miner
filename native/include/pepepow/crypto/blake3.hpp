#pragma once

#include "pepepow/crypto/hoohash_reference.hpp"

#include <cstddef>
#include <cstdint>

#if __cplusplus >= 202002L
#include <span>
#endif

namespace pepepow::crypto {

// C++17-compatible entry point used by the CUDA 11.8 translation unit.
[[nodiscard]] Hash256 blake3_hash(const std::uint8_t* data, std::size_t size);

#if __cplusplus >= 202002L
// Keep the convenient C++20 API for the native core without exposing std::span
// to nvcc/CUDA 11.8, whose active backend is intentionally compiled as C++17.
[[nodiscard]] inline Hash256 blake3_hash(std::span<const std::uint8_t> input) {
    return blake3_hash(input.data(), input.size());
}
#endif

} // namespace pepepow::crypto
