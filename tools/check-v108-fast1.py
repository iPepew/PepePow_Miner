import math
import struct


def f32(x: float) -> float:
    return struct.unpack('!f', struct.pack('!f', float(x)))[0]


def fast_exp_small(x: float) -> float:
    inv_ln2 = 1.44269504088896340735992468100189214
    ln2 = 0.693147180559945309417232121458176568
    k = int(round(x * inv_ln2))
    r = x - k * ln2
    p = 1.0 / 479001600.0
    p = 1.0 / 39916800.0 + r * p
    p = 1.0 / 3628800.0 + r * p
    p = 1.0 / 362880.0 + r * p
    p = 1.0 / 40320.0 + r * p
    p = 1.0 / 5040.0 + r * p
    p = 1.0 / 720.0 + r * p
    p = 1.0 / 120.0 + r * p
    p = 1.0 / 24.0 + r * p
    p = 1.0 / 6.0 + r * p
    p = 0.5 + r * p
    p = 1.0 + r * p
    p = 1.0 + r * p
    return p * (2.0 ** k)


def fast_rsqrt(z: float) -> float:
    zf = f32(z)
    seed = f32(1.0 / math.sqrt(zf))
    r = float(seed)
    r = r * (1.5 - 0.5 * z * r * r)
    r = r * (1.5 - 0.5 * z * r * r)
    return r


max_exp_rel = 0.0
for i in range(20001):
    x = -math.sqrt(2.0) + (2.0 * math.sqrt(2.0) * i / 20000.0)
    ref = math.exp(x)
    got = fast_exp_small(x)
    max_exp_rel = max(max_exp_rel, abs(got - ref) / ref)

max_rsqrt_rel = 0.0
# Logarithmic grid across the consensus z range.
for i in range(20001):
    exponent = math.log10(6.5e16) * i / 20000.0
    z = 10.0 ** exponent
    ref = 1.0 / math.sqrt(z)
    got = fast_rsqrt(z)
    max_rsqrt_rel = max(max_rsqrt_rel, abs(got - ref) / ref)

print(f'FAST1_EXP_MAX_REL={max_exp_rel:.3e}')
print(f'FAST1_RSQRT_MAX_REL={max_rsqrt_rel:.3e}')
if max_exp_rel > 2.0e-13:
    raise SystemExit('fast exp numerical contract failed')
if max_rsqrt_rel > 2.0e-13:
    raise SystemExit('fast rsqrt numerical contract failed')
print('V108_FAST1_NUMERICAL_CONTRACT=PASS')
