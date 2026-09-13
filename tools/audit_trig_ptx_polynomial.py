#!/usr/bin/env python3
"""CPU audit with a polynomial extracted from captured PTX, not hand-copied.

Source device.ptx SHA256:
05b950cd2943e5f713e7ccce47a63a4309f7fbb87d27853e74c1db713685b992
Fixture is BB11_29 through fd80; quadrant mapping is modeled separately.
This is not GPU execution or proof of the compiled candidate's sincos.
"""
import ctypes
import hashlib
import json
from pathlib import Path
import random
import re
import struct
from audit_trig_slowpath_final import reference_reduce, candidate_reduce, candidate_final


def encode(x):
    return struct.unpack('<Q', struct.pack('<d', x))[0]


def decode(x):
    return struct.unpack('<d', struct.pack('<Q', x))[0]


def compile_polynomial(source):
    """Translate only an allowlisted straight-line FP64 instruction subset."""
    lines = ['def replay(fd119):']
    counts = {}
    for line in source.splitlines():
        match = re.fullmatch(r'(mov\.f64|mul\.rn\.f64|fma\.rn\.f64)\s+(.+);', line.strip())
        if not match:
            raise ValueError(f'Unsupported PTX instruction: {line}')
        op, operands = match.groups()
        args = [a.strip() for a in operands.split(',')]
        def atom(a):
            if re.fullmatch(r'%fd\d+', a):
                return a[1:]
            if re.fullmatch(r'0d[0-9A-F]{16}', a):
                return f'decode(0x{a[2:]})'
            raise ValueError(a)
        dest, *values = map(atom, args)
        arity = {'mov.f64': 1, 'mul.rn.f64': 2, 'fma.rn.f64': 3}[op]
        assert len(values) == arity
        expr = (values[0] if arity == 1 else
                ' * '.join(values) if arity == 2 else
                f"fused({', '.join(values)})")
        lines.append(f'    {dest} = {expr}')
        counts[op] = counts.get(op, 0) + 1
    assert counts == {'mul.rn.f64': 1, 'mov.f64': 15, 'fma.rn.f64': 14}, counts
    lines.append('    return encode(fd80), encode(fd66)')
    fused = ctypes.CDLL('libm.so.6').fma
    fused.argtypes = [ctypes.c_double] * 3
    fused.restype = ctypes.c_double
    namespace = {'decode': decode, 'encode': encode, 'fused': fused}
    exec('\n'.join(lines), namespace)
    return namespace['replay']


def main():
    fixture = Path(__file__).with_name('fixtures') / 'trig_polynomial_sm70.ptx'
    source = fixture.read_text()
    assert hashlib.sha256(source.encode()).hexdigest() == '483af6855a12c1927895b547f4e43b2893d52271fbcd3c621c1fdbe989fb7971'
    replay = compile_polynomial(source)
    rng = random.Random(0x505458504f4c59)
    errors = 0
    first = None
    coverage = set()
    def check(raw):
        remainder, quadrant = reference_reduce(raw)
        s, c = replay(remainder)
        if quadrant & 1:
            s, c = c, s ^ (1 << 63)
        if quadrant & 2:
            s, c = s ^ (1 << 63), c ^ (1 << 63)
        actual = candidate_final(*candidate_reduce(raw))
        return (s, c), actual
    for i in range(1_000_000):
        exponent, sign = 31 + i % 26, (i // 26) & 1
        coverage.add((exponent, sign))
        raw = ((exponent + 1023) << 52) | rng.getrandbits(52) | (sign << 63)
        expected, actual = check(raw)
        if expected != actual:
            errors += 1
            if first is None:
                first = {'raw': f'{raw:016x}', 'expected': expected, 'actual': actual}
    edge_errors = 0
    for e in range(31, 57):
        for sign in (0, 1):
            for m in (0, 1, (1 << 51)-1, 1 << 51, (1 << 52)-2, (1 << 52)-1):
                expected, actual = check(((e+1023) << 52) | (sign << 63) | m)
                edge_errors += expected != actual
    report = dict(vectors=1_000_000, exponent_sign_classes=len(coverage),
                  mismatches=errors, edge_vectors=312, edge_mismatches=edge_errors,
                  first_mismatch=first, fixture_sha256=hashlib.sha256(source.encode()).hexdigest(),
                  reference_polynomial='parsed captured PTX; separate from candidate polynomial',
                  cuda_executed=False, compiled_candidate_verified=False,
                  limitation='CPU replay only; reduction reference is handwritten; compiled candidate GPU differential required')
    print(json.dumps(report, indent=2))
    assert len(coverage) == 52 and errors == edge_errors == 0


if __name__ == '__main__':
    main()
