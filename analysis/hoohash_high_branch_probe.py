#!/usr/bin/env python3
import json, math, random

SAMPLES = 512
RNG = random.Random(0x5045504557)
UINT32_MAX = 0xffffffff
THRESHOLDS = [1e-6, 1e-5, 1e-4, 1e-3, 1e-2, 1e-1, 1.0]
Y_BINS = [2**20, 2**30, 2**40, 2**50]


def u32be(b):
    return int.from_bytes(b, 'big')


def nonlinear_parts(x):
    one_base = x * 1e-6 / 8.0
    one = one_base - math.floor(one_base)
    two_base = x * 1e-6 / 4.0
    two = two_base - math.floor(two_base)
    if two < .25: y = x + (1.0 + two)
    elif two < .50: y = x - (1.0 + two)
    elif two < .75: y = x * (1.0 + two)
    else: y = x / (1.0 + two)
    if one < .33:
        return 0, y, math.exp(math.sin(y) + math.cos(y))
    if one < .66:
        s = math.sin(y)
        return 1, y, s*s
    return 2, y, 1.0 / math.sqrt(abs(y) + 1.0)


def mix(matrix, first_pass, nonce_mod, zero_high=False, stats=None):
    vector=[]
    for v in first_pass:
        vector.extend((v >> 4, v & 15))
    hash_mod=0
    for i in range(0,32,4): hash_mod ^= u32be(first_pass[i:i+4])
    product=[0.0]*64
    sw=0.0
    for i in range(64):
        for j in range(64):
            n=vector[j]
            if sw <= .02:
                if n:
                    x=matrix[i*64+j]*float(hash_mod)*float(n)+float(nonce_mod)
                    branch,y,out=nonlinear_parts(x)
                    if stats is not None:
                        stats['cold'] += 1
                        stats['branch'][branch] += 1
                        if branch == 2:
                            c = out * n * 1234.0
                            stats['high'] += 1
                            for t in THRESHOLDS:
                                if c < t: stats['high_contrib_lt'][str(t)] += 1
                            ay=abs(y)
                            for t in Y_BINS:
                                if ay >= t: stats['high_abs_y_ge'][str(t)] += 1
                    if zero_high and branch == 2: out=0.0
                    product[i] += out * n * 1234.0
            else:
                product[i] += matrix[i*64+j] * .0001 * n
            sw = product[i] / 1024.0 - math.floor(product[i] / 1024.0)
    mixed=bytearray(first_pass)
    for i in range(32):
        p=(int(product[i*2]) + int(product[i*2+1])) & 0xff
        mixed[i] ^= p
    return bytes(mixed)


def main():
    stats={'samples':SAMPLES,'cold':0,'branch':[0,0,0],'high':0,
           'high_contrib_lt':{str(t):0 for t in THRESHOLDS},
           'high_abs_y_ge':{str(t):0 for t in Y_BINS},
           'zero_high_mixed_mismatches':0}
    matrix=[RNG.getrandbits(32)/UINT32_MAX*1_000_000.0 for _ in range(4096)]
    for _ in range(SAMPLES):
        fp=bytes(RNG.getrandbits(8) for _ in range(32))
        nonce_mod=RNG.getrandbits(8)
        exact=mix(matrix,fp,nonce_mod,False,stats)
        approx=mix(matrix,fp,nonce_mod,True,None)
        if exact != approx: stats['zero_high_mixed_mismatches'] += 1
    stats['cold_per_nonce']=stats['cold']/SAMPLES
    stats['branch_fraction']=[x/stats['cold'] if stats['cold'] else 0 for x in stats['branch']]
    stats['zero_high_mismatch_fraction']=stats['zero_high_mixed_mismatches']/SAMPLES
    stats['high_contrib_lt_fraction']={k:v/stats['high'] if stats['high'] else 0 for k,v in stats['high_contrib_lt'].items()}
    stats['high_abs_y_ge_fraction']={k:v/stats['high'] if stats['high'] else 0 for k,v in stats['high_abs_y_ge'].items()}
    print(json.dumps(stats, indent=2, sort_keys=True))

if __name__ == '__main__': main()
