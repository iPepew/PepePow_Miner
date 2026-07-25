# PepePowMiner native core

This directory contains the standalone C++20/CUDA mining engine. It is isolated
from the existing Windows GUI launcher.

## Current state

- CMake-based C++20 project
- protocol-neutral mining job and share types
- canonical 80-byte PoW input serializer
- bit-exact CPU HooHash reference path
- CUDA first BLAKE3, FP64 matrix mix and final BLAKE3
- fused one-nonce-per-thread CUDA PoW pipeline
- CPU/GPU equality tests for each implemented stage
- CUDA throughput benchmark with configurable threads per block

The fused CUDA path is correctness-first. Strict FP64 behavior is retained with
`--fmad=false`; fast-math is not enabled. Architecture-specific tuning for Volta
and Ampere is performed only after CPU/GPU equality is confirmed on real GPUs.

## Configure and test without CUDA

```bash
cmake -S native -B build/native -DPEPEPOW_ENABLE_CUDA=OFF
cmake --build build/native --config Release
ctest --test-dir build/native -C Release --output-on-failure
```

## Configure with CUDA

```bash
cmake -S native -B build/native-cuda -DPEPEPOW_ENABLE_CUDA=ON
cmake --build build/native-cuda --config Release
ctest --test-dir build/native-cuda -C Release --output-on-failure
```

## Benchmark

```bash
./build/native-cuda/pepepow_cuda_benchmark 4096 0 64
```

Arguments are nonce count, CUDA device index and threads per block. Compare 32,
64 and 128 threads per block on each target GPU.

## ptxas profiling

Run from the `native` directory.

Tesla V100 (`sm_70`):

```bash
./scripts/profile_cuda.sh 70
./build-cuda-sm70/pepepow_cuda_benchmark 4096 0 32
./build-cuda-sm70/pepepow_cuda_benchmark 4096 0 64
./build-cuda-sm70/pepepow_cuda_benchmark 4096 0 128
```

RTX 3080 (`sm_86`):

```bash
./scripts/profile_cuda.sh 86
./build-cuda-sm86/pepepow_cuda_benchmark 4096 0 32
./build-cuda-sm86/pepepow_cuda_benchmark 4096 0 64
./build-cuda-sm86/pepepow_cuda_benchmark 4096 0 128
```

Windows PowerShell equivalents:

```powershell
./scripts/profile_cuda.ps1 -Architecture 70
./scripts/profile_cuda.ps1 -Architecture 86
```

The scripts save the compiler output to `ptxas.log`. Record the following for
`pow_pipeline_kernel` before attempting register limits:

- registers per thread
- stack frame bytes
- spill stores
- spill loads
- constant-memory usage

An experimental register cap can be supplied as the second Linux argument or
with `-MaxRegisters` in PowerShell, for example `profile_cuda.sh 70 96`. A lower
register count is not automatically faster: reject any cap that increases spill
traffic or reduces measured hashes per second.
