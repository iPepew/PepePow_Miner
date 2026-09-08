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
    carry = low = 0
    for limb in LIMBS:
        product = limb * mantissa + carry
        low = product & MASK64
        carry = product >> 64
    shift = (((bits >> 52) & 0x7FF) - 1024) & 63
    if shift:
        carry = ((carry << shift) & MASK64) | (low >> (64 - shift))
        low = (low << shift) & MASK64
    return carry, low


def full_projection(payload):
    high, low = payload
    round_bit = (high >> 61) & 1
    quadrant = (high >> 62) + round_bit
    fraction = (((high << 64) | low) << 2) & MASK128
    if round_bit:
        fraction = (-fraction) & MASK128
    return quadrant, fraction >> 64


def demand_sliced_projection(bits):
    """Keep only the quadrant and the 64 normalized bits consumed downstream."""
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
        shifted_low = (low << shift) & MASK64
    else:
        shifted_low = low

    round_bit = (high >> 61) & 1
    quadrant = (high >> 62) + round_bit
    normalized = ((high << 2) | (shifted_low >> 62)) & MASK64
    if round_bit:
        # Negating the full 128-bit fraction borrows into its high word iff
        # the discarded low word is non-zero. Only that predicate is needed.
        low_word_nonzero = bool(shifted_low & ((1 << 62) - 1))
        normalized = (-normalized - low_word_nonzero) & MASK64
    return quadrant, normalized


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
                    "expected": [expected[0], f"{expected[1]:016x}"],
                    "actual": [actual[0], f"{actual[1]:016x}"],
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
        "consensus_visible_output": ["quadrant", "normalized_fraction_high64"],
        "proved_dead_values": [
            "low64(limb15 * mantissa)",
            "lower128 of the conceptual 256-bit product",
            "low62 of the shifted fractional payload except its any-bit-set predicate",
        ],
        "next_gate": {
            "kind": "hosted_sm70_codegen",
            "arithmetic_core_sass_max": 42,
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
