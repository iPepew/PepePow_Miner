#!/usr/bin/env python3
"""Validate the old FastSolver 192-bit 1/(2*pi) reducer independently.

This is a proof/profiling tool only. It does not change mining semantics.
It emulates fast_phase_frac64() from the historical FastSolver V2/V3 branch
and compares the returned 64-bit phase fraction against a high-precision
Decimal reference over the full magnitude range relevant to HooHash.
"""

from __future__ import annotations

import argparse
from decimal import Decimal, getcontext
import math
import random
import struct

getcontext().prec = 110
PI = Decimal(
    "3.1415926535897932384626433832795028841971693993751058209749445923078164062862089986280348253421170679"
)
TAU = PI * 2
TWO64 = 1 << 64
MASK64 = TWO64 - 1
LUT_INTERVALS = 98304

# floor(2^192 / (2*pi)), same constant as historical FastSolver V2/V3.
C0 = 0x36D8A5664F10E410
C1 = 0x7F09D5F47D4D3770
C2 = 0x28BE60DB9391054A


def bits_of(x: float) -> int:
    return struct.unpack("<Q", struct.pack("<d", x))[0]


def mul53x192(m: int) -> tuple[int, int, int, int]:
    # Straight arbitrary-precision equivalent of the CUDA limb multiplication.
    c = C0 | (C1 << 64) | (C2 << 128)
    p = m * c
    return tuple((p >> (64 * i)) & MASK64 for i in range(4))


def reducer_frac64(y: float) -> int | None:
    b = bits_of(abs(y))
    eb = (b >> 52) & 0x7FF
    if eb == 0 or eb == 0x7FF:
        return None
    exponent = int(eb) - 1023
    shift_to_point = 244 - exponent
    if shift_to_point < 64 or shift_to_point > 256:
        return None
    mantissa = (b & 0x000FFFFFFFFFFFFF) | 0x0010000000000000
    p0, p1, p2, p3 = mul53x192(mantissa)
    limbs = (p0, p1, p2, p3, 0)
    bitpos = shift_to_point - 64
    limb = bitpos >> 6
    sh = bitpos & 63
    lo = limbs[limb]
    hi = limbs[limb + 1]
    frac = lo if sh == 0 else ((lo >> sh) | ((hi << (64 - sh)) & MASK64))
    frac &= MASK64
    if y < 0.0 and frac != 0:
        frac = (-frac) & MASK64
    return frac


def decimal_from_float(x: float) -> Decimal:
    # Decimal.from_float is exact for the binary64 input value.
    return Decimal.from_float(x)


def reference_frac(y: float) -> Decimal:
    q = decimal_from_float(y) / TAU
    # Decimal % semantics are awkward for negatives; use floor explicitly.
    k = q.to_integral_value(rounding="ROUND_FLOOR")
    return q - k


def circular_error(a: Decimal, b: Decimal) -> Decimal:
    d = abs(a - b)
    return min(d, Decimal(1) - d)


def sample_value(rng: random.Random) -> float:
    # HooHash x is normally dominated by matrix<=1e6 * uint32 * nibble<=15,
    # and y can be scaled by <2. Include generous headroom around that domain.
    e = rng.randint(-20, 57)
    m = 1.0 + rng.random()
    x = math.ldexp(m, e)
    if rng.getrandbits(1):
        x = -x
    return x


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--samples", type=int, default=250_000)
    ap.add_argument("--seed", type=int, default=0x50455045)
    args = ap.parse_args()

    rng = random.Random(args.seed)
    tested = 0
    fallback = 0
    worst_cycles = Decimal(0)
    worst_y = 0.0
    worst_frac = 0
    same_lut_cell = 0
    within_quarter_cell = 0

    # Explicit edge magnitudes plus randomized coverage.
    values = [
        1e-12, 1e-9, 1e-3, 1.0, math.pi, 1e6, 1e12, 1e15,
        1e16, 6.5e16, 1.3e17, 2.0e17,
    ]
    values += [-x for x in values]
    values += [sample_value(rng) for _ in range(args.samples)]

    cell = Decimal(1) / Decimal(LUT_INTERVALS)
    for y in values:
        if not math.isfinite(y) or y == 0.0:
            continue
        got = reducer_frac64(y)
        if got is None:
            fallback += 1
            continue
        tested += 1
        got_d = Decimal(got) / Decimal(TWO64)
        ref = reference_frac(y)
        err = circular_error(got_d, ref)
        if err > worst_cycles:
            worst_cycles = err
            worst_y = y
            worst_frac = got
        # Cell metrics are useful because the historical LUT had 98,304 intervals.
        if int(got_d * LUT_INTERVALS) == int(ref * LUT_INTERVALS):
            same_lut_cell += 1
        if err <= cell / 4:
            within_quarter_cell += 1

    worst_cells = worst_cycles * Decimal(LUT_INTERVALS)
    print(f"samples_requested={args.samples}")
    print(f"tested={tested}")
    print(f"fallback={fallback}")
    print(f"same_lut_cell={same_lut_cell}")
    print(f"same_lut_cell_pct={100.0 * same_lut_cell / tested if tested else 0:.9f}")
    print(f"within_quarter_cell_pct={100.0 * within_quarter_cell / tested if tested else 0:.9f}")
    print(f"worst_phase_error_cycles={worst_cycles}")
    print(f"worst_phase_error_lut_cells={worst_cells}")
    print(f"worst_y={worst_y:.17g}")
    print(f"worst_frac64=0x{worst_frac:016x}")

    # This gate only validates the reducer resolution relative to the historical
    # LUT grid. It deliberately does NOT claim consensus equivalence of LUT interpolation.
    if tested < args.samples // 2:
        print("RESULT=FAIL insufficient reducer coverage")
        return 2
    if worst_cells >= Decimal("0.25"):
        print("RESULT=FAIL reducer error too large for guarded LUT work")
        return 3
    print("RESULT=PASS reducer is precise enough to proceed to guarded LUT error analysis")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
