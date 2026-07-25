# Changelog

## v0.1.0 — Foundation Release

- Added C++20 CPU reference implementation for the PepePow/HooHash pipeline.
- Added fused CUDA implementation for BLAKE3, FP64 matrix mixing and final BLAKE3.
- Added CPU/GPU bit-for-bit correctness tests.
- Added configurable CUDA benchmark utility.
- Added PTXAS profiling scripts for Linux/HiveOS and Windows PowerShell.
- Added register, stack-frame and spill diagnostics.
- Added constant-memory matrix broadcast in the production CUDA path.
- Replaced separate `sin` and `cos` calls with CUDA `sincos` in the nonlinear branch.
- Added warp-divergence and nonlinear-path profiling utilities.
- Verified CUDA tests on RTX 3080 with CUDA 12.4.

### Known limitations

- No production Stratum client or share-submission loop yet.
- Tesla V100 performance tuning remains in progress.
- Current CUDA kernel is correctness-first and not yet competitive with mature closed-source miners.
