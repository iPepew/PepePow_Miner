#!/usr/bin/env python3
"""Conservative bound helper for HooHash high nonlinear branch.

For high(y) = 1/sqrt(abs(y)+1), derive an upper bound using only the
binary exponent of |y|. This is intentionally conservative and is a proof
primitive for a future interval guard; it does NOT change consensus code.
"""

from __future__ import annotations

import math
import random
import struct


def exponent_floor_abs(y: float) -> int:
    """Return k such that |y| >= 2**k for finite non-zero y."""
    a = abs(y)
    if not math.isfinite(a) or a == 0.0:
        raise ValueError("expected finite non-zero y")
    bits = struct.unpack(">Q", struct.pack(">d", a))[0]
    exp = (bits >> 52) & 0x7FF
    if exp == 0:
        # Subnormal: exact floor(log2(a)) is determined by mantissa MSB.
        mant = bits & ((1 << 52) - 1)
        return -1074 + (mant.bit_length() - 1)
    return int(exp) - 1023


def high_exact(y: float) -> float:
    return 1.0 / math.sqrt(abs(y) + 1.0)


def high_upper_bound_from_exponent(y: float) -> float:
    """Strict upper bound for high_exact(y), computed without sqrt.

    If |y| >= 2**k then sqrt(|y|+1) >= sqrt(2**k), therefore
    high(y) <= 2**(-k/2).  Odd k is handled directly with ldexp/sqrt(2)
    in this offline proof helper.  CUDA production code can encode the same
    bound with exponent arithmetic and precomputed constants.
    """
    k = exponent_floor_abs(y)
    if k & 1:
        # 2^(-(k//2)) / sqrt(2) for odd positive/negative k alike.
        return math.ldexp(1.0 / math.sqrt(2.0), -(k // 2))
    return math.ldexp(1.0, -(k // 2))


def main() -> None:
    # Deterministic exponent sweep plus random mantissas.  The important
    # HooHash region observed by the probe is roughly |y| >= 2^40, but we
    # validate a much wider normal range.
    rng = random.Random(0x5045504557)
    checked = 0
    worst_ratio = 0.0
    for k in range(-100, 1001):
        for _ in range(64):
            m = 1.0 + rng.random()  # [1,2)
            y = math.ldexp(m, k)
            exact = high_exact(y)
            bound = high_upper_bound_from_exponent(y)
            if exact > bound:
                raise AssertionError(
                    f"bound violation k={k}: exact={exact:.17g} bound={bound:.17g}"
                )
            worst_ratio = max(worst_ratio, exact / bound)
            checked += 1

    print(f"PASS checked={checked} worst_exact_over_bound={worst_ratio:.17g}")
    print("NOTE: this proves only the per-term upper bound. Consensus-safe elision")
    print("still requires row/pair interval guards and exact fallback before BLAKE3.")


if __name__ == "__main__":
    main()
