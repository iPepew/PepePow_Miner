# PepePow Miner v0.8.0 Grand Update

## Objective

Reach and validate at least **2.000 MH/s** on the reference RTX 3080 while preserving exact HooHash V110 consensus and stable live-pool operation.

The target is not considered reached by an estimate or a short internal peak. It requires:

- sustained live-pool average at or above 2.000 MH/s;
- accepted shares greater than zero;
- zero miner-caused rejected shares;
- zero CUDA errors;
- zero new NVIDIA NVRM Xid events;
- CPU/CUDA critical-path and consensus-vector validation.

## Why the v0.7.x micro-tuning phase is closed

The tested launch geometry, register caps, zero-nibble guards, split pipeline and hybrid pipeline variants produced either measurement noise, a regression, or instability.

The v0.7.3 hybrid result established the plateau:

- monolithic baseline: 1,472,157 H/s;
- full split: 1,471,553 H/s;
- final split: 1,472,105 H/s;
- first split: validation failure;
- best uplift: 0.0000%.

Further launch-parameter permutations are therefore not part of v0.8.0.

## Architectural changes in the first v0.8.0 campaign

### Exact selector decode

The current nonlinear path materializes two positive fractional doubles. The v0.8.0 exact-selector candidate determines the `0.33 / 0.66` region directly from the binary64 remainder and only materializes the second fraction used in the transform. The comparison uses the exact binary64 encodings of the consensus thresholds.

### Dual-nonce execution

The dual-nonce candidates map two consecutive nonces to each CUDA thread.

Two implementations are compared:

1. sequential dual-nonce execution, which measures launch and scheduling effects without changing the per-nonce operation order;
2. interleaved dual-nonce ILP, which interleaves independent HooHash states at cell granularity to expose instruction-level parallelism across expensive FP64 transcendental operations.

### Combined candidate

The exact-selector and dual-nonce ILP changes are also benchmarked together at 64- and 128-thread launch geometries and one/two-block launch bounds.

## Validation matrix

Every profile must complete:

- clean Release CUDA build for `sm_86`;
- `ctest`;
- canonical Header80 CPU/CUDA validation;
- seven 16,777,216-nonce benchmark runs;
- register, stack and spill collection;
- GPU clock, power and temperature sampling.

A non-baseline candidate with at least 0.5% uplift enters a twenty-run 33,554,432-nonce offline stability gate. Only a stable candidate with at least 10% internal uplift is marked ready for live A/B/A validation.

## Release policy

v0.6.0-PR remains the installed stable fallback. The v0.8.0 branch is experimental and must not replace the stable package until the live gate passes.
