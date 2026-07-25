#pragma once

#include "pepepow/core/types.hpp"

namespace pepepow {

[[nodiscard]] Header80 build_header80(const MiningJob& job) noexcept;

} // namespace pepepow
