#include "pepepow/crypto/blake3.hpp"

#include <blake3.h>

namespace pepepow::crypto {

Hash256 blake3_hash(const std::uint8_t* data, std::size_t size) {
    Hash256 output{};
    blake3_hasher hasher;
    blake3_hasher_init(&hasher);
    blake3_hasher_update(&hasher, data, size);
    blake3_hasher_finalize(&hasher, output.data(), output.size());
    return output;
}

} // namespace pepepow::crypto
