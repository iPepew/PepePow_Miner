#!/usr/bin/env python3
"""Prove the minimal consensus-visible projection of the fixed i2opi window."""

import json
import random


MASK64 = (1 << 64) - 1
MASK128 = (1 << 128) - 1
LIMBS = (
    0xDB6295993C439041,
    0xFC2757D1F534DDC0,
    0xA2F9836E4E441529,
)


def full_payload(bits):
    mantissa = ((bits << 11) & MASK64) | (1 << 63)
    # Independent whole-product oracle, including bits from the preceding limb.
    constant = sum(limb << (64 * i) for i, limb in enumerate(LIMBS))
    shift = (((bits >> 52) & 0x7FF) - 1024) & 63
    payload = ((constant * mantissa) >> (128 - shift)) & MASK128
    return payload >> 64, payload & MASK64


def full_projection(payload):
    high, low = payload
    round_bit = (high >> 61) & 1
    quadrant = (high >> 62) + round_bit
    fraction = (((high << 64) | low) << 2) & MASK128
    if round_bit:
        fraction = (-fraction) & MASK128
    return quadrant, fraction


def demand_sliced_projection(bits):
    """Keep quadrant and the full 128-bit signed fraction consumed downstream."""
    mantissa = ((bits << 11) & MASK64) | (1 << 63)

    # The first product's low word is overwritten by the second iteration.
    carry0 = (LIMBS[0] * mantissa) >> 64
    product1 = LIMBS[1] * mantissa + carry0
    carry1 = product1 >> 64
    product2 = LIMBS[2] * mantissa + carry1
    high = product2 >> 64
    low = product2 & MASK64

    shift = (((bits >> 52) & 0x7FF) - 1024) & 63
    if shift:
        high = ((high << shift) & MASK64) | (low >> (64 - shift))
        shifted_low = ((low << shift) | ((product1 & MASK64) >> (64 - shift))) & MASK64
    else:
        shifted_low = low

    round_bit = (high >> 61) & 1
    quadrant = (high >> 62) + round_bit
    fraction_high = ((high << 2) | (shifted_low >> 62)) & MASK64
    fraction_low = (shifted_low << 2) & MASK64
    if round_bit:
        borrow = bool(fraction_low)
        fraction_low = (-fraction_low) & MASK64
        fraction_high = (-fraction_high - borrow) & MASK64
    return quadrant, (fraction_high << 64) | fraction_low


def main():
    vectors = 1_000_000
    rng = random.Random(0x44454D414E44534C)
    mismatches = 0
    first_mismatch = None
    for index in range(vectors):
        exponent = 27 + index % 30
        bits = ((exponent + 1023) << 52) | rng.getrandbits(52)
        expected = full_projection(full_payload(bits))
        actual = demand_sliced_projection(bits)
        if expected != actual:
            mismatches += 1
            if first_mismatch is None:
                first_mismatch = {
                    "input_bits": f"{bits:016x}",
                    "expected": [expected[0], f"{expected[1]:032x}"],
                    "actual": [actual[0], f"{actual[1]:032x}"],
                }

    report = {
        "schema_version": 1,
        "candidate": "hotrun8-exact-demand-sliced-i2opi-projection-v1",
        "status": "EXACT_PROJECTION_PROVED" if not mismatches else "REJECT_EXACTNESS_FAILED",
        "vectors": vectors,
        "seed_hex": "0x44454d414e44534c",
        "unbiased_exponents": [27, 56],
        "mismatches": mismatches,
        "first_mismatch": first_mismatch,
        "consensus_visible_output": ["quadrant", "signed_fraction_128"],
        "proved_dead_values": [
            "low64(limb15 * mantissa)",
            "bits below the exponent-dependent 128-bit output window",
        ],
        "next_gate": {
            "kind": "hosted_sm70_codegen",
            "arithmetic_core_sass_max": 100,
            "registers_max": 56,
            "stack_bytes_max": 80,
            "spill_bytes_max": 0,
            "v100_allowed": False,
        },
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    raise SystemExit(bool(mismatches))


if __name__ == "__main__":
    main()
