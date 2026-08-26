#!/usr/bin/env python3
"""Conservative bound helper for HooHash high nonlinear branch.

For high(y) = 1/sqrt(abs(y)+1), derive an upper bound using only the
binary exponent of |y|. This is a proof primitive for guarded elision; it
does not change consensus code.
"""
from __future__ import annotations
import math, random, struct

def exponent_floor_abs(y: float) -> int:
    a=abs(y)
    if not math.isfinite(a) or a == 0.0: raise ValueError('finite non-zero y required')
    bits=struct.unpack('>Q',struct.pack('>d',a))[0]
    exp=(bits>>52)&0x7ff
    if exp==0:
        mant=bits&((1<<52)-1)
        return -1074+(mant.bit_length()-1)
    return int(exp)-1023

def high_exact(y: float)->float: return 1.0/math.sqrt(abs(y)+1.0)

def high_upper_bound_from_exponent(y: float)->float:
    k=exponent_floor_abs(y)
    if k&1: return math.ldexp(1.0/math.sqrt(2.0),-(k//2))
    return math.ldexp(1.0,-(k//2))

def main():
    rng=random.Random(0x5045504557); checked=0; worst=0.0
    for k in range(-100,1001):
        for _ in range(64):
            y=math.ldexp(1.0+rng.random(),k)
            e=high_exact(y); b=high_upper_bound_from_exponent(y)
            if e>b: raise AssertionError((k,e,b))
            worst=max(worst,e/b); checked+=1
    print(f'PASS checked={checked} worst_exact_over_bound={worst:.17g}')
    print('Guarded production use still requires dependent-state interval checks and exact fallback.')
if __name__=='__main__': main()
