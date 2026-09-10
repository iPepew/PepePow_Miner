#!/usr/bin/env python3
"""Independent full-integer oracle for the libdevice three-limb window.

PTX evidence: device.ptx, BB12_4..BB12_6 loads local+8 and shifts it
into the low output word. The oracle multiplies the whole 192-bit constant,
not a second copy of the candidate's carry chain. No CUDA execution claimed.
"""
import json
import random
from prove_demand_sliced_i2opi_projection import (
    LIMBS, MASK64, MASK128, full_projection,
)


def oracle(bits):
    m = ((bits << 11) & MASK64) | (1 << 63)
    constant = sum(limb << (64 * i) for i, limb in enumerate(LIMBS))
    shift = (((bits >> 52) & 0x7ff) - 1024) & 63
    payload = ((constant * m) >> (128 - shift)) & MASK128
    return full_projection((payload >> 64, payload & MASK64))


def repaired(bits):
    m = ((bits << 11) & MASK64) | (1 << 63)
    carry0 = (LIMBS[0] * m) >> 64
    p1 = LIMBS[1] * m + carry0
    p2 = LIMBS[2] * m + (p1 >> 64)
    high, low = p2 >> 64, p2 & MASK64
    shift = (((bits >> 52) & 0x7ff) - 1024) & 63
    if shift:
        high = ((high << shift) | (low >> (64 - shift))) & MASK64
        low = ((low << shift) | ((p1 & MASK64) >> (64 - shift))) & MASK64
    return full_projection((high, low))


def legacy(bits):
    m = ((bits << 11) & MASK64) | (1 << 63)
    carry = 0
    for limb in LIMBS:
        product = limb * m + carry
        carry, low = product >> 64, product & MASK64
    shift = (((bits >> 52) & 0x7ff) - 1024) & 63
    payload = ((((carry << 64) | low) << shift) & MASK128)
    return full_projection((payload >> 64, payload & MASK64))


def main():
    rng = random.Random(0x44454D414E44534C)
    old_errors = new_errors = cases = 0
    first = None
    for i in range(1_000_000):
        bits = ((27 + i % 30 + 1023) << 52) | rng.getrandbits(52)
        expected, old, new = oracle(bits), legacy(bits), repaired(bits)
        cases += 1
        old_errors += expected != old
        new_errors += expected != new
        if expected != old and first is None:
            first = {"input_bits": f"{bits:016x}",
                     "expected_fraction128": f"{expected[1]:032x}",
                     "old_fraction128": f"{old[1]:032x}"}
    edge_errors = 0
    for exponent in range(27, 57):
        for mantissa in (0, 1, (1 << 51) - 1, 1 << 51, (1 << 52) - 2, (1 << 52) - 1):
            bits = ((exponent + 1023) << 52) | mantissa
            edge_errors += oracle(bits) != repaired(bits)
    print(json.dumps({"vectors": cases, "old_fraction128_mismatches": old_errors,
        "repaired_fraction128_mismatches": new_errors,
        "edge_vectors": 180, "repaired_edge_mismatches": edge_errors,
        "first_mismatch": first, "cuda_executed": False,
        "final_fp64_exactness": "NOT_TESTED", "v100_allowed": False}, indent=2))
    assert old_errors > 0 and new_errors == 0 and edge_errors == 0


if __name__ == "__main__":
    main()
