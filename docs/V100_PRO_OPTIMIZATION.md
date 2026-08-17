# Tesla V100 HooHashV110 optimization log

This document records measured baselines, architectural changes and merge gates for the V100 performance track. Hashrate numbers are never promoted from estimates; only target-rig measurements belong in the measured table.

## Correctness invariants

- HooHashV110 real-block KAT must pass on every mining GPU before Stratum mining begins.
- CUDA floating-point compilation remains strict: `--fmad=false --prec-div=true --prec-sqrt=true --ftz=false`.
- Pool difficulty uses the standard `0xffff` diff1 basis used by the PEPEPOW HooHash reference implementation; no artificial 65,536 share-target multiplier.
- Rejected shares are a hard regression signal. A build that is faster but produces invalid shares is not a candidate.
- Stable/main is not replaced by an experiment until the target-rig test passes.
- Every accepted performance baseline is preserved on a dedicated baseline branch before the next experiment starts.

## Measured target-rig history

| Build | GPU | Avg hashrate | KAT | Rejected | Reconnects | Avg power | Avg GPU util | Result |
|---|---|---:|---|---:|---:|---:|---:|---|
| `dev-63bb3dc` | Tesla V100-SXM2-16GB | ~6.254 MH/s | PASS | 0 | 0 | — | ~98.8% | accepted baseline |
| `dev-04296fb` | Tesla V100-SXM2-16GB | ~6.27 MH/s live | PASS | 0 | 0 | — | — | HiveOS per-GPU mapping validated |
| `dev-c684413` | Tesla V100-SXM2-16GB | **5.326 MH/s** | PASS | 0 | 0 | 114.8 W | 98.9% | rejected: −15% performance regression |
| `v100-c98eafd` | Tesla V100-SXM2-16GB | **8.402 MH/s** | PASS | 0 | 0 | **161.9 W** | **99.9%** | **KNOWN-GOOD BASELINE** |

### `v100-c98eafd` 20-minute soak evidence

Target-rig report, 2026-08-18:

- measured interval: **1200 s** after **30 s** warmup;
- average: **8.402 MH/s**;
- minimum: **8.350 MH/s**;
- maximum: **8.437 MH/s**;
- telemetry samples: **239**;
- accepted/rejected: **0 / 0**;
- reconnects: **0**;
- miner state at end: **online**;
- average GPU power: **161.9 W**;
- average GPU temperature: **55.4°C**;
- maximum GPU temperature: **58°C**;
- average GPU utilization: **99.9%**;
- HiveOS stats callback: complete, including per-GPU hashrate, temperature, fan field, A/R and PCI bus mapping.

The exact source state is preserved as branch `baseline/v100-8.402mh` from commit `c98eafdf8692901175af6b6f4e43c4e9adc38e39`.

## Rejected experiment: `dev-c684413`

The first aggressive hot-loop rewrite removed `double product[64]`, used a BLAKE3 midstate and moved the matrix to CUDA constant memory. It was consensus-correct but slower on real V100 hardware: **5.326 MH/s**, approximately 15% below the then-current 6.27 MH/s baseline. This proves that reduced local state/register pressure alone is not a valid optimization criterion for HooHash on Volta.

Do not reintroduce the constant-memory matrix variant without independent target-rig evidence.

## Current known-good architecture: `v100-c98eafd`

- CUDA toolkit 11.8;
- strict HooHash floating-point flags;
- 64 threads per block;
- 262,144 nonce scan batches;
- 64×64 FP64 HooHash matrix in device global memory;
- device-side target comparison;
- per-GPU worker and HiveOS telemetry;
- automatic extranonce2 rollover when a worker exhausts its assigned 32-bit nonce space;
- startup real-block consensus KAT on every CUDA device.

The sm_70 mining kernel compiles without spill loads/stores. The 20-minute soak is the performance/correctness reference for all following changes.

## Current experiment: persistent CUDA scan state

The next A/B candidate intentionally leaves the HooHash kernel, block geometry and 262,144 batch size unchanged. Only host/device scan overhead is changed:

1. allocate the device header once per backend instead of once per scan batch;
2. allocate the device result buffer once per backend;
3. copy header and rebuild the HooHash matrix only when the 76-byte job prefix changes;
4. copy the target only when difficulty/target changes;
5. remove the redundant explicit `cudaDeviceSynchronize()` before the blocking result D2H copy.

This experiment is accepted only if the real V100 remains consensus-correct and exceeds the **8.402 MH/s** known-good baseline with `R=0`.

## HiveOS integration gates

The custom miner stats callback must provide aligned arrays for:

- `hs[]` — per-GPU hashrate;
- `temp[]` — per-GPU temperature;
- `fan[]` — fan percentage when NVIDIA exposes it; Tesla SXM `N/A` is represented as numeric `0`, never fabricated;
- `bus_numbers[]` — physical PCI mapping;
- `ar[]` — pool-accepted and rejected shares.

Actual accepted shares are pool events. `A=0` during a test is not converted into a fake accepted share.

## Performance target

30 MH/s on Tesla V100-SXM2-16GB remains the engineering target, not a guaranteed figure. Each optimization must be isolated, compiled with ptxas diagnostics and validated on the target rig against the 8.402 MH/s baseline before it becomes the new reference.