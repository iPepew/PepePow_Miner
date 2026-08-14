# PepeW Miner v1.0.9 — V100 Dual-Engine Autotune

**Performance & Stability Edition**

> PepeW — твоя монета. Твои правила.

## Status

Experimental pre-release for physical NVIDIA Tesla V100 / Volta `sm_70` validation.

No v1.0.9 hashrate is claimed until the physical autotuner and pool tests complete.

## Why v1.0.9 exists

The best confirmed PepeW V100 result before this release is `6.094 MH/s` from the exact `service24` test. Later experiments proved two dead ends:

- per-worker async mailboxes: `0.673 MH/s`;
- polynomial exp + Newton rsqrt: `5.476 MH/s` steady.

v1.0.9 returns to the exact service architecture, removes the fixed 768-thread shared-memory footprint and adds physical block-geometry autotuning. It also includes an optional restricted-domain trig engine aimed at the dominant large-argument `sin/sincos` cost.

## Two V100 engines

### exact

- standard CUDA double `sincos`, `sin`, `exp`, `sqrt`;
- exact selector and HooHash state path;
- dynamic shared scratch;
- runtime block geometry.

### fasttrig

- same HooHash state, selector, exp and sqrt;
- same final double `sincos` evaluation;
- replaces only the general large-argument trig reduction for `2^31 <= |y| < 2^57`;
- obtains the nearest `pi/2` multiple from 128 fixed bits of `2/pi`;
- builds the remainder with three 19-bit integer chunks and four non-overlapping `pi/2` double chunks;
- falls back to standard CUDA `sincos` outside the restricted domain.

The fasttrig path is treated as a candidate solver, not as a source of truth. CPU reference validation remains mandatory.

## Physical autotune

Modes:

```text
exact
fasttrig
```

Block sizes:

```text
96 128 160 192 224 256 288 320 352 384 416
448 480 512 544 576 608 640 672 704 736 768
```

Each mode/geometry must pass 32 deterministic CPU/GPU HooHash nonce comparisons before its performance result is eligible. Three timed runs are used and the median H/s is compared.

The winner is cached by physical GPU UUID and a combined SHA256 of both worker binaries. A binary change invalidates the cache automatically.

If no profile passes consensus validation, v1.0.9 refuses to start mining.

## Dynamic shared memory

The old service24 layout reserved scratch for 768 threads for every block. v1.0.9 uses:

```text
shared_bytes = 8 + 28 * threads
```

Examples:

```text
96 threads  ->  2,696 bytes
192 threads ->  5,384 bytes
256 threads ->  7,176 bytes
384 threads -> 10,760 bytes
768 threads -> 21,512 bytes
```

This allows the V100 to test several smaller independently schedulable blocks per SM while keeping the existing exact service topology.

## Cache policy

The HooHash kernel requests:

```text
cudaFuncCachePreferL1
cudaFuncAttributePreferredSharedMemoryCarveout = cudaSharedmemCarveoutMaxL1
```

Dynamic shared memory requested by the kernel remains allocated; the carveout is a preference intended to leave maximum room for L1 when possible.

## Console / HiveOS design

Restored startup identity:

```text
PepeW Miner v1.0.9 - Performance & Stability Edition
PepeW - твоя монета. Твои правила.
```

Runtime output remains compact:

- no giant ASCII logo;
- no emoji event markers;
- no wallet/password echo;
- selected V100 engine and block geometry are visible;
- per-GPU and aggregate hashrate/power/Accepted/Rejected telemetry remains enabled.

## Package identity

```text
CUSTOM_NAME=PepeW-Miner-v1.0.9
CUSTOM_VERSION=1.0.9
Archive: PepeW-Miner-v1.0.9-HiveOS.tar.gz
Root:    PepeW-Miner-v1.0.9/
```

The package contains both worker binaries and both physical autotune helpers.

## Validation before publication

CI must pass:

- restricted trig numerical/synthetic-HooHash contract;
- exact CUDA build for `sm_70`;
- fasttrig CUDA build for `sm_70`;
- final-ELF Volta fatbin checks for both workers and autotune helpers;
- core tests;
- shell syntax checks;
- package-root/manifest checks;
- binary SHA256 checks;
- package sanitation checks.

## Physical acceptance sequence

1. install the v1.0.9 pre-release on the Tesla V100;
2. allow the first-start autotuner to finish;
3. capture the selected `mode`, `threads`, and benchmark H/s;
4. verify Accepted increases and Rejected is not caused by GPU/CPU mismatch;
5. run a 120-second passive test;
6. if the result is healthy, run the standard 600-second passive test;
7. compare against the confirmed `6.094 MH/s` PepeW baseline and the external V100 reference.

Target remains `30 MH/s`, but the release notes do not claim the target has been reached.
