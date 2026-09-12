#!/usr/bin/env python3
"""CPU binary64 replay of the captured sm_70 libdevice reduction boundary.

Requires IEEE binary64 and libm fma. This is not CUDA differential proof.
Reference PTX: trig-diagnostic/device.ptx BB11_26..29 and BB12_6.
PTX SHA256: 05b950cd2943e5f713e7ccce47a63a4309f7fbb87d27853e74c1db713685b992
Keep the original fast reducer below 2**31; using the slow reducer there
is a different operation sequence even if its fraction128 is exact.
"""
import ctypes
import json
import random
import struct
from prove_demand_sliced_i2opi_projection import MASK64, full_payload

libm = ctypes.CDLL('libm.so.6')
fma = libm.fma
fma.argtypes = [ctypes.c_double] * 3
fma.restype = ctypes.c_double


def number(bits):
    return struct.unpack('>d', struct.pack('>Q', bits))[0]


def bits(value):
    return struct.unpack('>Q', struct.pack('>d', value))[0]


def slow(raw):
    high, low = full_payload(raw)
    rounding = (high >> 61) & 1
    quadrant = (high >> 62) + rounding
    fraction = (((high << 64) | low) << 2) & ((1 << 128) - 1)
    if rounding:
        fraction = -fraction & ((1 << 128) - 1)
    high, low = fraction >> 64, fraction & MASK64
    leading = 64 - high.bit_length()
    normalized = ((fraction << leading) >> 64) & MASK64
    product = normalized * 0xc90fdaa22168c235
    top = product >> 64
    renorm = 0 < top < (1 << 63)
    significant = ((product << int(renorm)) >> 64) & MASK64
    rounded = (((((significant + 1) & MASK64) >> 10) + 1) >> 1)
    remainder = ((0x3fe0000000000000 - ((leading + int(renorm)) << 52)) + rounded) & MASK64
    remainder |= (raw & (1 << 63)) ^ (rounding << 63)
    return number(remainder), -quadrant if raw >> 63 else quadrant


def fast(x):
    q = round(x * number(0x3fe45f306dc9c883))
    r = fma(-float(q), number(0x3ff921fb54442d18), x)
    r = fma(-float(q), number(0x3c91a62633145c00), r)
    r = fma(-float(q), number(0x397b839a252049c0), r)
    return r, q


def polynomial(r, q):
    z = r * r
    c = number(0xbda8ff8320fd8164)
    for coefficient in (0x3e21eea7c1ef8528, 0xbe927e4f8e06e6d9,
                        0x3efa01a019ddbce9, 0xbf56c16c16c15d47,
                        0x3fa5555555555551, 0xbfe0000000000000,
                        0x3ff0000000000000):
        c = fma(c, z, number(coefficient))
    s = number(0x3de5db65f9785eba)
    for coefficient in (0xbe5ae5f12cb0d246, 0x3ec71de369ace392,
                        0xbf2a01a019db62a1, 0x3f81111111110818,
                        0xbfc5555555555554, 0):
        s = fma(s, z, number(coefficient))
    s = fma(s, r, r)
    if q & 1:
        s, c = c, -s
    if q & 2:
        s, c = -s, -c
    return bits(s), bits(c)


def main():
    assert polynomial(*fast(number(0x41ce39e66cfe6bc2))) == (
        0x3fe69d4098529a79, 0xbfe6a3fbb48788d4)
    rng = random.Random(0x4650363441554449)
    differences = outputs = 0
    first = None
    # Exercise the four exponent classes where candidate bypassed fast path.
    for i in range(1000000):
        raw = ((27 + i % 4 + 1023) << 52) | rng.getrandbits(52) | ((i % 2) << 63)
        x = number(raw)
        reference, candidate = fast(x), slow(raw)
        mismatch = polynomial(*reference) != polynomial(*candidate)
        differences += bits(reference[0]) != bits(candidate[0])
        outputs += mismatch
        if mismatch and first is None:
            first = dict(input_bits=f'{raw:016x}',
                         reference_remainder=f'{bits(reference[0]):016x}',
                         candidate_remainder=f'{bits(candidate[0]):016x}',
                         reference_sincos=[f'{v:016x}' for v in polynomial(*reference)],
                         candidate_sincos=[f'{v:016x}' for v in polynomial(*candidate)])
    print(json.dumps(dict(vectors=1000000, exponents=[27, 30],
        remainder_mismatches=differences, final_polynomial_mismatches=outputs,
        first_mismatch=first, cuda_executed=False,
        scope='CPU replay of captured PTX, not compiled candidate execution'), indent=2))
    assert outputs > 0, 'Expected to reproduce the pre-fix domain error'


if __name__ == '__main__':
    main()
