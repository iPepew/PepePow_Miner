import math
import random
import struct

TWO_OVER_PI_128 = int('a2f9836e4e441529fc2757d1f534ddc0', 16)
PIO2 = (
    float.fromhex('0x1.921fb54000000p+0'),
    float.fromhex('0x1.10b4610000000p-30'),
    float.fromhex('0x1.a626330000000p-58'),
    float.fromhex('0x1.45c06e0000000p-86'),
)
MASK19 = (1 << 19) - 1
FAST_LIMIT = float(1 << 31)
CUSTOM_LIMIT = float(1 << 57)


def dd_add_d(hi: float, lo: float, x: float) -> tuple[float, float]:
    s = hi + x
    bb = s - hi
    err = (hi - (s - bb)) + (x - bb)
    t = lo + err
    z = s + t
    zz = t - (z - s)
    return z, zz


def nearest_quadrant_abs(value: float) -> int:
    bits = struct.unpack('<Q', struct.pack('<d', value))[0]
    exponent = ((bits >> 52) & 0x7ff) - 1023
    mantissa = (1 << 52) | (bits & ((1 << 52) - 1))
    product = mantissa * TWO_OVER_PI_128
    shift = 180 - exponent
    q, remainder = divmod(product, 1 << shift)
    half = 1 << (shift - 1)
    if remainder > half or (remainder == half and (q & 1)):
        q += 1
    return q


def reduce_large(value: float) -> tuple[int, float]:
    negative = math.copysign(1.0, value) < 0.0
    a = abs(value)
    q = nearest_quadrant_abs(a)
    chunks = (
        float(q & MASK19),
        float((q >> 19) & MASK19) * float(1 << 19),
        float(q >> 38) * float(1 << 38),
    )
    hi, lo = a, 0.0
    for pio2 in PIO2:
        for chunk in reversed(chunks):
            if chunk:
                hi, lo = dd_add_d(hi, lo, -(chunk * pio2))
    remainder = hi + lo
    if negative:
        return -q, -remainder
    return q, remainder


def reduced_sincos(value: float) -> tuple[float, float]:
    a = abs(value)
    if a < FAST_LIMIT or a >= CUSTOM_LIMIT or not math.isfinite(value):
        return math.sin(value), math.cos(value)
    q, remainder = reduce_large(value)
    s = math.sin(remainder)
    c = math.cos(remainder)
    quadrant = q & 3
    if quadrant == 0:
        return s, c
    if quadrant == 1:
        return c, -s
    if quadrant == 2:
        return -s, -c
    return -c, s


def nonlinear(x: float, reduced: bool) -> float:
    one = x * 0.000001 / 8.0
    one -= math.floor(one)
    two = x * 0.000001 / 4.0
    two -= math.floor(two)
    if two < 0.25:
        y = x + (1.0 + two)
    elif two < 0.50:
        y = x - (1.0 + two)
    elif two < 0.75:
        y = x * (1.0 + two)
    else:
        y = x / (1.0 + two)
    if one < 0.33:
        if reduced:
            sine, cosine = reduced_sincos(y)
        else:
            sine, cosine = math.sin(y), math.cos(y)
        return math.exp(sine + cosine)
    if one < 0.66:
        if y == math.pi / 2.0 or y == 3.0 * math.pi / 2.0:
            return 0.0
        sine = reduced_sincos(y)[0] if reduced else math.sin(y)
        return sine * sine
    return 1.0 / math.sqrt(abs(y) + 1.0)


def synthetic_mix(matrix, first_pass: bytes, nonce: int, reduced: bool) -> bytes:
    hash_mod = 0
    for i in range(8):
        hash_mod ^= int.from_bytes(first_pass[i * 4:(i + 1) * 4], 'big')
    vector = []
    for byte in first_pass:
        vector.extend((byte >> 4, byte & 0x0f))
    product = [0.0] * 64
    sw = 0.0
    nonce_mod = float(nonce & 0xff)
    for row_index in range(64):
        total = 0.0
        row = matrix[row_index]
        for cell_index in range(64):
            value = vector[cell_index]
            if sw <= 0.02:
                x = row[cell_index] * float(hash_mod) * float(value) + nonce_mod
                total += nonlinear(x, reduced) * float(value) * 1234.0
            else:
                total += row[cell_index] * 0.0001 * float(value)
            sw = total / 1024.0
            sw -= math.floor(sw)
        product[row_index] = total
    mixed = bytearray(32)
    for i in range(32):
        combined = int(product[i * 2]) + int(product[i * 2 + 1])
        mixed[i] = first_pass[i] ^ (combined & 0xff)
    return bytes(mixed)


def main() -> None:
    rng = random.Random(0x10970)
    max_sin_abs = 0.0
    max_cos_abs = 0.0
    for _ in range(100_000):
        value = (rng.random() * 2.0 - 1.0) * 1.13e17
        sine, cosine = reduced_sincos(value)
        ref_sine, ref_cosine = math.sin(value), math.cos(value)
        max_sin_abs = max(max_sin_abs, abs(sine - ref_sine))
        max_cos_abs = max(max_cos_abs, abs(cosine - ref_cosine))
    if max_sin_abs > 2.5e-15 or max_cos_abs > 2.5e-15:
        raise SystemExit(
            f'reducer trig error too high: sin={max_sin_abs:.3e} cos={max_cos_abs:.3e}')

    matrix = None
    mix_matches = 0
    mix_samples = 2048
    for sample in range(mix_samples):
        if sample % 64 == 0:
            matrix = [
                [float(rng.getrandbits(32)) / 4294967295.0 * 1_000_000.0 for _ in range(64)]
                for _ in range(64)
            ]
        first_pass = bytes(rng.getrandbits(8) for _ in range(32))
        nonce = rng.getrandbits(32)
        reference = synthetic_mix(matrix, first_pass, nonce, False)
        candidate = synthetic_mix(matrix, first_pass, nonce, True)
        if candidate != reference:
            raise SystemExit(
                f'reducer synthetic HooHash mismatch sample={sample} '
                f'ref={reference.hex()} candidate={candidate.hex()}')
        mix_matches += 1

    print(f'V109_REDUCER_MAX_SIN_ABS={max_sin_abs:.3e}')
    print(f'V109_REDUCER_MAX_COS_ABS={max_cos_abs:.3e}')
    print(f'V109_REDUCER_SYNTHETIC_MIX_MATCH={mix_matches}/{mix_samples}')
    print('V109_RESTRICTED_TRIG_CONTRACT=PASS')


if __name__ == '__main__':
    main()
