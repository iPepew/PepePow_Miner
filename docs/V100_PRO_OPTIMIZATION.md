# Tesla V100 HooHashV110 optimization log

This document records measured baselines, architectural changes and merge gates for the V100 performance track. Hashrate numbers are never promoted from estimates; only target-rig measurements belong in the measured table.

## Correctness invariants

- HooHashV110 real-block KAT must pass on every mining GPU before Stratum mining begins.
- CUDA floating-point compilation remains strict: `--fmad=false --prec-div=true --prec-sqrt=true --ftz=false`.
- Pool difficulty uses the standard `0xffff` diff1 basis used by the PEPEPOW HooHash reference implementation; no artificial 65,536 share-target multiplier.
- Rejected shares are a hard regression signal. A build that is faster but produces invalid shares is not a candidate.
- Stable/main is not replaced by an experiment until the target-rig test passes.

## Measured target-rig baseline

| Build | GPU | Avg hashrate | KAT | Rejected | Reconnects | Notes |
|---|---|---:|---|---:|---:|---|
| `dev-63bb3dc` | Tesla V100-SXM2-16GB | ~6.254 MH/s | PASS | 0 | 0 | pre-hot-loop validated baseline; ~98.8% GPU util |
| `dev-04296fb` | Tesla V100-SXM2-16GB | ~6.27 MH/s live | PASS | 0 | 0 | per-GPU HiveOS mapping validated |
| `dev-c684413` | Tesla V100-SXM2-16GB | **pending target-rig test** | startup KAT required | pending | pending | first professional hot-loop candidate |

## `dev-c684413` architectural changes

1. **No per-nonce 80-byte header reconstruction.** The first 64-byte BLAKE3 block is precompressed to a job midstate; only the final 16-byte block is processed for each nonce.
2. **Job-constant HooHash matrix cache.** The masked-header matrix seed is computed on the host and the 64×64 FP64 matrix is copied to CUDA constant memory only when the seed changes.
3. **No `double product[64]` per mining thread.** Rows are reduced sequentially in consensus order and each mixed output byte is emitted after its two rows are complete.
4. **Exact zero-nibble short circuit.** Expensive nonlinear math is skipped for a zero nibble while the sequential switch variable is still updated.
5. **Reference register policy.** `--maxrregcount=128` is used together with strict FP flags.
6. **Same hash path for KAT and mining.** The diagnostic kernel and search kernel call the same optimized HooHash implementation.

## Compiler evidence for V100 (`sm_70`)

From CUDA 11.8 `ptxas -v` for `dev-c684413`:

- mining `search_kernel`: **127 registers**
- stack frame: **176 bytes**
- spill stores: **0 bytes**
- spill loads: **0 bytes**
- HooHash constant-memory state: ~32 KiB matrix plus small job constants

The one-thread diagnostic KAT kernel uses spills, but it runs only during startup validation and is not in the mining throughput path.

## HiveOS integration gates

The custom miner stats callback must provide aligned arrays for:

- `hs[]` — per-GPU hashrate
- `temp[]` — per-GPU temperature
- `fan[]` — fan percentage when NVIDIA exposes it; Tesla SXM `N/A` is represented as numeric `0`, never fabricated
- `bus_numbers[]` — physical PCI mapping
- `ar[]` — pool-accepted and rejected shares

CI contains a deterministic two-GPU callback test. Actual accepted shares are pool events; a short test with `A=0` is not converted into a fake accepted share.

## Target-rig test gate for `dev-c684413`

Before any merge:

1. real V100 startup KAT = PASS;
2. 30 s warmup + at least 180 s measured interval;
3. average hashrate > 6.254 MH/s baseline;
4. rejected shares = 0;
5. reconnects <= 1;
6. record average/max temperature, average power and GPU utilization;
7. verify HiveOS shows per-card hashrate and temperature/fan fields;
8. leave the miner online long enough to observe a real accepted share when practical.

## Performance target

30 MH/s on Tesla V100-SXM2-16GB is the engineering target, not a guaranteed figure. The next optimization step is chosen from target-rig evidence, not from synthetic hashrate reporting. If the first hot-loop candidate remains below target, investigate launch amortization/persistent result buffers, reference throughput geometry, instruction mix and Volta occupancy while preserving the KAT gate.