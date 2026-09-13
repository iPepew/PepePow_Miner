#!/usr/bin/env python3
"""Shared-reconstruction consistency audit for exponent classes 31..56.

Reference uses one full 192x64-bit product. Candidate uses the production
three-word carry chain. Both replay the captured sm_70 binary64 reconstruction
and polynomial sequence; candidate additionally replays its nested sincos and
quadrant switch. Shared reconstruction and polynomial functions mean this
is NOT an independent final-FP64 proof. This is CPU replay, not CUDA execution.
"""
import json
import random
from audit_trig_fp64_reconstruction import bits, fast, number, polynomial
from prove_demand_sliced_i2opi_projection import LIMBS, MASK64, MASK128


def reconstruct(raw, high, low):
    rounding = (high >> 61) & 1
    quadrant = (high >> 62) + rounding
    fraction = (((high << 64) | low) << 2) & MASK128
    if rounding:
        fraction = -fraction & MASK128
    fh, fl = fraction >> 64, fraction & MASK64
    leading = 64 - fh.bit_length()
    normalized = ((fraction << leading) >> 64) & MASK64
    product = normalized * 0xc90fdaa22168c235
    top = product >> 64
    renormalize = 0 < top < (1 << 63)
    significant = ((product << int(renormalize)) >> 64) & MASK64
    rounded = (((((significant + 1) & MASK64) >> 10) + 1) >> 1)
    remainder = ((0x3fe0000000000000 -
                 ((leading + int(renormalize)) << 52)) + rounded) & MASK64
    remainder |= (raw & (1 << 63)) ^ (rounding << 63)
    return number(remainder), -quadrant if raw >> 63 else quadrant


def reference_reduce(raw):
    mantissa = ((raw << 11) & MASK64) | (1 << 63)
    constant = sum(limb << (64 * i) for i, limb in enumerate(LIMBS))
    shift = (((raw >> 52) & 0x7ff) - 1024) & 63
    payload = ((constant * mantissa) >> (128 - shift)) & MASK128
    return reconstruct(raw, payload >> 64, payload & MASK64)


def candidate_reduce(raw):
    mantissa = ((raw << 11) & MASK64) | (1 << 63)
    carry0 = (LIMBS[0] * mantissa) >> 64
    product1 = LIMBS[1] * mantissa + carry0
    product2 = LIMBS[2] * mantissa + (product1 >> 64)
    high, low = product2 >> 64, product2 & MASK64
    shift = (((raw >> 52) & 0x7ff) - 1024) & 63
    if shift:
        high = ((high << shift) | (low >> (64 - shift))) & MASK64
        low = ((low << shift) | ((product1 & MASK64) >> (64 - shift))) & MASK64
    return reconstruct(raw, high, low)


def flip(raw):
    return raw ^ (1 << 63)


def candidate_final(remainder, quadrant):
    inner_r, inner_q = fast(remainder)
    assert inner_q == 0 and bits(inner_r) == bits(remainder)
    sine, cosine = polynomial(inner_r, inner_q)
    q = quadrant & 3
    if q == 1:
        sine, cosine = cosine, flip(sine)
    elif q == 2:
        sine, cosine = flip(sine), flip(cosine)
    elif q == 3:
        sine, cosine = flip(cosine), sine
    return sine, cosine


def check(raw):
    reference = reference_reduce(raw)
    candidate = candidate_reduce(raw)
    return reference, candidate, polynomial(*reference), candidate_final(*candidate)


def main():
    rng = random.Random(0x534c4f5750415448)
    reduce_errors = output_errors = 0
    first = None
    coverage = {}
    for i in range(1_000_000):
        exponent = 31 + i % 26
        sign = (i // 26) & 1
        key = f"{exponent}:{sign}"
        coverage[key] = coverage.get(key, 0) + 1
        raw = ((exponent + 1023) << 52) | rng.getrandbits(52) | (sign << 63)
        reference, candidate, expected, actual = check(raw)
        reduce_errors += (bits(reference[0]), reference[1]) != (bits(candidate[0]), candidate[1])
        output_errors += expected != actual
        if expected != actual and first is None:
            first = {'input_bits': f'{raw:016x}',
                     'reference': [f'{v:016x}' for v in expected],
                     'candidate': [f'{v:016x}' for v in actual]}
    assert set(coverage) == {f"{e}:{s}" for e in range(31, 57) for s in (0, 1)}
    assert max(coverage.values()) - min(coverage.values()) <= 1
    edge_errors = 0
    for exponent in range(31, 57):
        for mantissa in (0, 1, (1 << 51) - 1, 1 << 51,
                         (1 << 52) - 2, (1 << 52) - 1):
            for sign in (0, 1):
                raw = ((exponent + 1023) << 52) | mantissa | (sign << 63)
                _, _, expected, actual = check(raw)
                edge_errors += expected != actual
    report = {'vectors': 1_000_000, 'exponents': [31, 56],
              'random_exponent_sign_classes': len(coverage),
              'random_class_counts': coverage,
              'independent_final_fp64_proof': False,
              'limitation': 'Shared reconstruction and polynomial; independent reference and GPU differential still required',
              'reduction_mismatches': reduce_errors,
              'final_sincos_mismatches': output_errors,
              'edge_vectors': 312, 'edge_mismatches': edge_errors,
              'first_mismatch': first, 'cuda_executed': False,
              'reference': 'full 192x64 integer product plus captured PTX FP64 replay',
              'candidate': 'production carry chain plus nested sincos and quadrant switch'}
    print(json.dumps(report, indent=2))
    assert reduce_errors == output_errors == edge_errors == 0


if __name__ == '__main__':
    main()
