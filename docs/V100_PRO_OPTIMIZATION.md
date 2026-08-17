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
| `v100-c98eafd` | Tesla V100-SXM2-16GB | **8.402 MH/s** | PASS | 0 | 0 | **161.9 W** | **99.9%** | accepted baseline; 20-minute soak |
| `v100-5d96212` | Tesla V100-SXM2-16GB | **8.542 MH/s** | PASS | 0 | 0 | **165.0 W** | **100.0%** | **CURRENT KNOWN-GOOD BASELINE** |

### `v100-5d96212` 5-minute A/B evidence

Target-rig report, 2026-08-18:

- measured interval: **300 s** after **30 s** warmup;
- average: **8.542 MH/s**;
- minimum: **8.509 MH/s**;
- maximum: **8.573 MH/s**;
- telemetry samples: **59**;
- accepted/rejected: **0 / 0**;
- reconnects: **0**;
- miner state at end: **online**;
- average GPU power: **165.0 W**;
- average GPU temperature: **57.3°C**;
- maximum GPU temperature: **58°C**;
- average GPU utilization: **100.0%**;
- HiveOS stats callback: complete, ending at **8.540 MH/s**, 58°C, `A/R 0/0` and PCI bus 2.

This is a clean A/B against `v100-c98eafd`: the HooHash kernel, 64-thread block geometry and 262,144-nonce batch are unchanged. The gain comes from persistent CUDA scan state and removal of redundant host/device setup between batches.

The measured source commit is `5d962124f5c35e68be6b237b8ac03ef1ae7e03d9`. The accepted source state plus current hardware-test tooling is preserved as branch `baseline/v100-8.542mh`.

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

## Rejected experiment: `dev-c684413`

The first aggressive hot-loop rewrite removed `double product[64]`, used a BLAKE3 midstate and moved the matrix to CUDA constant memory. It was consensus-correct but slower on real V100 hardware: **5.326 MH/s**, approximately 15% below the then-current 6.27 MH/s baseline. This proves that reduced local state/register pressure alone is not a valid optimization criterion for HooHash on Volta.

Do not reintroduce the constant-memory matrix variant without independent target-rig evidence.

## Current known-good architecture: `v100-5d96212`

- CUDA toolkit 11.8;
- strict HooHash floating-point flags;
- 64 threads per block;
- 262,144 nonce scan batches;
- 64×64 FP64 HooHash matrix in device global memory;
- device-side target comparison;
- persistent device header and result buffers;
- header/matrix rebuild only when the 76-byte job prefix changes;
- target upload only when difficulty/target changes;
- blocking D2H result copy used as the required stream synchronization point;
- per-GPU worker and HiveOS telemetry;
- automatic extranonce2 rollover when a worker exhausts its assigned 32-bit nonce space;
- startup real-block consensus KAT on every CUDA device.

The sm_70 mining kernel compiles without spill loads/stores. This 8.542 MH/s result is the performance/correctness reference for the next isolated experiments.

## Current experiment: SM70 register-pressure A/B

The next candidate changes **only compiler register pressure** on the exact 8.542 MH/s mining core. The first isolated candidate uses `--maxrregcount=128` and publishes to a separate `hiveos-v100-r128-test` channel.

Why this is isolated:

1. HooHash math is unchanged;
2. matrix placement is unchanged;
3. 64 threads/block is unchanged;
4. 262,144 nonce/batch is unchanged;
5. persistent CUDA state is unchanged;
6. only the compiler register cap differs.

CI ptxas diagnostics are inspected before target-rig testing. If limiting registers creates material spill traffic, the candidate is rejected before promotion even if it builds successfully.

## HiveOS integration gates

The custom miner stats callback must provide aligned arrays for:

- `hs[]` — per-GPU hashrate;
- `temp[]` — per-GPU temperature;
- `fan[]` — fan percentage when NVIDIA exposes it; Tesla SXM `N/A` is represented as numeric `0`, never fabricated;
- `bus_numbers[]` — physical PCI mapping;
- `ar[]` — pool-accepted and rejected shares.

Actual accepted shares are pool events. `A=0` during a test is not converted into a fake accepted share.

## Performance target

30 MH/s on Tesla V100-SXM2-16GB remains the engineering target, not a guaranteed figure. Each optimization must be isolated, compiled with ptxas diagnostics and validated on the target rig against the **8.542 MH/s** baseline before it becomes the new reference.