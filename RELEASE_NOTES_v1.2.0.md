# PepeW Miner v1.2.0 — V100 Magic LUT Solver

**Performance & Stability Edition**

> PepeW — твоя монета. Твои правила.

## Status

Experimental Tesla V100 / Volta `sm_70` pre-release.

No v1.2.0 pool hashrate is claimed before physical V100 testing.

## Why another execution model

Previous physical experiments established a very clear ceiling for the old exact execution family:

- best confirmed PepeW pool result: **6.094 MH/s** (`v1.0.5 test4`);
- v1.0.9 official 600-second pool result: **5.871 MH/s**;
- v1.1.0 physical autotune: exact `6.630 MH/s` benchmark, while the new warp-cohort profiles remained below exact;
- live v1.1.0 pool telemetry again stayed around **5.86–5.87 MH/s**.

Block geometry, service-warp count, async mailboxes, custom exact trig reduction, polynomial exp/rsqrt and warp-cohort scheduling therefore did not produce the required order-of-magnitude improvement.

v1.2.0 attacks the arithmetic and memory path itself.

## Magic LUT engine

The speculative V100 engine keeps:

- exact HooHash selector logic;
- exact SW-state logic;
- FP64 row accumulation;
- exact BLAKE3 stages;
- exact CPU validation before pool submission.

For the two periodic nonlinear branches it removes large-argument runtime trig/exp work.

### Direct fixed-point phase extraction

For `2^31 <= |y| < 2^57`, the periodic phase is obtained directly from a 53-bit double mantissa multiplied by 128 fixed bits of `2/pi`.

The kernel extracts a 32-bit full-cycle phase from the 192-bit product. It does not first form a large floating-point `y - q*pi/2` remainder.

Outside the restricted domain the standard CUDA double math path remains available.

### 65,536-node cubic-Hermite tables

Two periodic functions are precomputed once on the host and copied to the V100:

```text
f0(theta) = exp(sin(theta) + cos(theta))
f1(theta) = sin(theta)^2
```

Each node stores:

```text
value
derivative
```

and the kernel performs FP64 cubic-Hermite interpolation between adjacent nodes.

The two tables occupy approximately 2 MiB total and are intended to reside predominantly in the V100 L2 cache.

### Warm-path change

The old path can use a 512 KiB `cell × nibble` table for warm cells.

The v1.2.0 Magic solver instead uses the 32 KiB scaled matrix in constant memory and performs one FP64 multiply by the nibble value:

```text
constant-cache broadcast + FP64 multiply
```

This reduces lookup footprint and exploits the strong native FP64 capability of Volta.

### Optional fast reciprocal square root

The third nonlinear branch can be tested in two modes:

```text
0 = exact 1/sqrt()
1 = FP32 rsqrt seed + one FP64 Newton step
```

The physical autotuner decides whether the faster mode preserves enough exact HooHash results to improve effective work rate.

## Physical autotune: effective rate, not fake raw rate

The v1.2.0 autotuner measures both the exact baseline and speculative Magic profiles.

Magic candidates:

```text
threads/block: 128, 256
blocks/SM:     1, 2, 4, 6, 8
fast_rsqrt:    0, 1
```

Before timing, each profile evaluates **256 deterministic nonce values** and compares complete GPU HooHash output against the CPU reference.

The reported score is:

```text
effective_hps = raw_hps × exact_hash_quality
```

Example:

```text
raw:       28.0 MH/s
quality:   0.96
effective: 26.88 MH/s
```

A high raw hashrate with poor exact-hash quality therefore cannot win merely because it displays a large number.

Default safeguards:

```text
minimum Magic quality: 90%
selection requirement: Magic effective rate >= 1.05 × exact rate
```

If no Magic profile clears those gates, the miner starts the exact service768 fallback.

## Larger persistent batch

The exact fallback keeps the established pool batch:

```text
262,144 nonce
```

When Magic wins physical autotune, the launcher uses:

```text
1,228,800 nonce
```

This amortizes kernel-launch overhead and matches the persistent high-throughput execution model rather than the short exact-service cadence.

## Pool correctness

Regardless of physical autotune quality, a GPU candidate is not trusted by itself.

The miner rebuilds the candidate header and calculates the exact CPU HooHash. A share is submitted only if:

```text
GPU candidate hash == CPU hash
AND
CPU hash meets target
```

Thus the speculative engine is allowed to skip some valid hashes if its approximation differs, but it is not allowed to submit a known-invalid share.

## Console identity

```text
PepeW Miner v1.2.0 - Performance & Stability Edition
PepeW - твоя монета. Твои правила.
```

The V100 startup line reports:

```text
engine
profile
threads
blocks/SM
fast rsqrt mode
validation quality
raw autotune MH/s
effective autotune MH/s
chunk size
```

Runtime output remains ASCII-safe and compact.

## Package identity

```text
CUSTOM_NAME=PepeW-Miner-v1.2.0
CUSTOM_VERSION=1.2.0
Archive: PepeW-Miner-v1.2.0-HiveOS.tar.gz
Root:    PepeW-Miner-v1.2.0/
```

## Acceptance sequence

1. Install v1.2.0 on the physical Tesla V100.
2. Do not interrupt first-start autotune.
3. Capture all `engine=magic` raw/effective/quality rows.
4. Capture the final selected profile.
5. If Magic is selected, immediately confirm pool Accepted shares and CPU-validation diagnostics.
6. Run a short 120-second passive capture.
7. Only after that run the standard 600-second pool test.

The development target remains **30 MH/s on Tesla V100**, but v1.2.0 does not claim the target has been reached before physical validation.
