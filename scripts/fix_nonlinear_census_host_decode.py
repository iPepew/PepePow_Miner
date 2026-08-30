#!/usr/bin/env python3
from pathlib import Path

path = Path('native/src/cuda/v1/header80_backend_part07.inc')
s = path.read_text()

anchor = '''    unsigned long long ns=0,nc=0,ne=0,n2=0,nr=0,emin=0,emax=0,smin=0,smax=0,rmin=0,rmax=0;\n'''
insert = anchor + '''    auto nlc_host_double_from_bits = [](unsigned long long bits) {\n        union BitsDouble { unsigned long long u; double d; } v{};\n        v.u = bits;\n        return v.d;\n    };\n    auto nlc_host_signed_from_ordered = [&](unsigned long long ordered) {\n        const unsigned long long bits = (ordered & 0x8000000000000000ULL)\n            ? (ordered ^ 0x8000000000000000ULL) : ~ordered;\n        return nlc_host_double_from_bits(bits);\n    };\n'''
if anchor not in s:
    raise SystemExit('nonlinear census report anchor not found')
s = s.replace(anchor, insert, 1)

s = s.replace('nlc_signed_from_ordered(emin)', 'nlc_host_signed_from_ordered(emin)')
s = s.replace('nlc_signed_from_ordered(emax)', 'nlc_host_signed_from_ordered(emax)')
s = s.replace('nlc_signed_from_ordered(smin)', 'nlc_host_signed_from_ordered(smin)')
s = s.replace('nlc_signed_from_ordered(smax)', 'nlc_host_signed_from_ordered(smax)')
s = s.replace('__longlong_as_double(static_cast<long long>(rmin))', 'nlc_host_double_from_bits(rmin)')
s = s.replace('__longlong_as_double(static_cast<long long>(rmax))', 'nlc_host_double_from_bits(rmax)')

for bad in (
    'const double exp_min = ne ? nlc_signed_from_ordered',
    'const double exp_max = ne ? nlc_signed_from_ordered',
    'const double sin2_min = n2 ? nlc_signed_from_ordered',
    'const double sin2_max = n2 ? nlc_signed_from_ordered',
    'const double rsqrt_min = nr ? __longlong_as_double',
    'const double rsqrt_max = nr ? __longlong_as_double',
):
    if bad in s:
        raise SystemExit(f'host decode replacement incomplete: {bad}')

path.write_text(s)
print('fixed nonlinear census host-side bit decoding')
