# PepeW V100 v2 — Foztor-guided implementation plan

Target: Tesla V100-SXM2-16GB / SM70, PEPEW HooHashV110.

Current measured PepeW candidate: ~9.82 MH/s with the R128 build. Engineering target remains 30 MH/s.

## Do not spend the next cycle on isolated register/block tuning

The current kernel is already near 100% GPU utilization. The gap to the Foztor reference requires less work per nonce, not merely more resident warps.

## V2 implementation order

1. Dedicated PEPEW/SM70 mining path.
   - specialize the 76-byte PEPEW header prefix;
   - precompute the first BLAKE3 block chaining value once per job;
   - avoid reconstructing an 80-byte header in every nonce thread.

2. TransformFactor hot path.
   - replace repeated generic FP64 `floor(product / 1024)` work with an exact SM70-friendly predicate/remainder path;
   - validate the optimized predicate against the reference over a large differential sample before pool testing.

3. Reduce transient local state.
   - keep matrix in global memory for Volta broadcast/L2 behavior;
   - test paired-row streaming separately from matrix-placement changes;
   - skip zero nibbles only when it is bit-identical to the reference state transition.

4. Candidate validation layer.
   - keep exact HooHash verification before pool submission;
   - track GPU candidate count, validation failures and pool rejects separately;
   - never promote a faster build with degraded valid-share rate.

5. Table-assisted transcendental research.
   - Foztor 1.4.23 exposes optimized exp/TransformFactor LUT infrastructure and an `exp-threshold` quality/speed control;
   - implement only after the live V100 Foztor run establishes the actual PEPEW solver quality/speed tradeoff;
   - table-assisted exp must use an exact/fallback path sufficient to keep candidate validation rate high.

6. SM70 autotuner.
   - tune TPB, blocks/SM, batch, shared-memory budget, cache preference and carveout;
   - preserve the winner per V100/device configuration.

## Promotion gates

- startup real-block KAT PASS;
- exact candidate validation enabled;
- rejected shares = 0 during A/B;
- no reconnect/stale regression;
- measured valid hashrate improvement on the same V100 and same clocks;
- record power, clocks, temperature and GPU utilization.

## Immediate data dependency

Run `lab/foztor-v100-live-benchmark.sh` on the same V100 without changing clocks. Capture Foztor's PEPEW autotune (`tpb`, `blocks`, `batch`, `warp`), hashrate, power, clocks, CPU-validation failures and accepted/rejected shares. This determines which V2 optimization receives priority first.
