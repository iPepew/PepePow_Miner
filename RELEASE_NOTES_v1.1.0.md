# PepeW Miner v1.1.0 — Persistent Warp Cohort

**Performance & Stability Edition**

> PepeW — твоя монета. Твои правила.

## Status

Experimental pre-release for NVIDIA Tesla V100 / Volta `sm_70`.

No new v1.1.0 hashrate is claimed until physical V100 autotune and pool validation are complete.

## Why this is a 1.1.0 release

The v1.0.x series mapped the limits of the existing HooHash execution model:

```text
v1.0.5 test3 service3   5.801 MH/s
v1.0.5 test4 service24  6.094 MH/s  <- best confirmed pool baseline
v1.0.7 async3           0.673 MH/s
v1.0.8 fast1            5.476 MH/s
v1.0.9 exact dual-auto  5.871 MH/s  <- official 600 s result
```

v1.0.9 also demonstrated that:

- 768 threads remained the best geometry of the service kernel;
- smaller CUDA blocks did not unlock additional performance;
- fasttrig was slower than the standard exact path;
- all 619 inspected GPU candidates matched CPU reference exactly;
- the current service architecture remains near a ~6 MH/s real-pool ceiling.

v1.1.0 therefore changes the HooHash execution model rather than changing another math primitive or block-size setting.

## New engine: warp-cohort persistent

The new kernel runs 32 independent nonce state machines per warp.

A nonce that reaches a cheap warm cell continues immediately. A nonce that reaches a rare nonlinear cell stores its exact pending input in registers and temporarily stops advancing. Other lanes continue until enough nonlinear work has accumulated. The parked lanes then execute a dense nonlinear cohort before resuming their individual state machines.

This removes the block-wide service barriers from the new hot loop without introducing the shared atomics and polling that made `async3` extremely slow.

### Cohort kernel resource profile

CUDA 12.8.1 / `sm_70`:

```text
Registers/thread: 128
Stack:            192 bytes
Spill stores:     0
Spill loads:      0
Barriers:         0
Shared memory:    0
Local memory:     0
```

The proven exact service kernel remains compiled into the same miner as fallback.

## Physical V100 autotune

Safety anchor:

```text
engine=exact
threads=768
```

Experimental engine:

```text
engine=cohort
threads=256
```

Cohort threshold sweep:

```text
4 8 12 16 20 24 28 32
```

Persistent grid density sweep:

```text
1 2 4 8 10 12 blocks/SM
```

Benchmark reference batch:

```text
1,228,800 nonce
3 timed rounds
median H/s
```

Each profile must pass **64 deterministic CPU/GPU HooHash nonce comparisons** before its performance result is eligible.

The cohort engine must beat the exact baseline by at least 2% before automatic selection. Otherwise v1.1.0 deliberately keeps the known exact path.

If the exact safety baseline itself fails CPU/GPU consensus validation, mining does not start.

## Consensus and share safety

v1.1.0 keeps:

- exact FP64 HooHash math;
- exact selector logic;
- exact SW state;
- FMA contraction disabled;
- per-profile CPU/GPU validation before autotune timing;
- exact CPU validation of every GPU share candidate before pool submission.

Delaying a parked nonlinear operation does not reorder operations inside that nonce: the nonce state cannot advance to the next matrix cell until its own nonlinear result is committed.

## HiveOS

```text
CUSTOM_NAME=PepeW-Miner-v1.1.0
CUSTOM_VERSION=1.1.0
Archive: PepeW-Miner-v1.1.0-HiveOS.tar.gz
Root:    PepeW-Miner-v1.1.0/
```

Startup identity:

```text
PepeW Miner v1.1.0 - Performance & Stability Edition
PepeW - твоя монета. Твои правила.
```

The console also reports the selected engine, threads, cohort threshold, blocks/SM and autotune benchmark result.

## CI gates

The release workflow verifies:

- CUDA Toolkit 12.8.1 and `sm_70` support;
- final miner and autotune helper contain Volta device code;
- exact and cohort kernels exist in the final ELF;
- cohort kernel has no shared-memory allocation or local-memory spills;
- generated CUDA source contains no NUL bytes;
- HiveOS scripts pass shell syntax validation;
- archive root matches `CUSTOM_NAME`;
- binary SHA256 passes after staging;
- package contains no `__pycache__` or legacy `-HiveOS/` root directory.

## Physical acceptance plan

1. Install v1.1.0 on the Tesla V100.
2. Let first-start autotune finish without interruption.
3. Record exact baseline and the best cohort profile.
4. Confirm the selected engine and parameters in startup output.
5. Confirm `[HOOHASH] Consensus V110 verified` and Accepted shares.
6. Run a 120-second passive capture.
7. If healthy, run the standard 600-second passive capture.
8. Compare real pool H/s to the confirmed 6.094 MH/s best PepeW baseline.

Development target remains:

```text
30 MH/s on Tesla V100
```

The target is not a release claim.
