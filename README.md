# PepePow Miner

Open-source native C++20/CUDA miner foundation for PepePow and the HooHash V110 proof-of-work pipeline.

## v0.1.0 Foundation Release

This release contains a correctness-first native implementation with:

- CPU reference pipeline
- fused NVIDIA CUDA pipeline
- bit-for-bit CPU/GPU validation tests
- CUDA benchmark utility
- PTXAS register, stack and spill profiling
- warp-divergence and nonlinear-path diagnostic tools
- Linux, HiveOS and Windows build support through CMake

The current CUDA implementation preserves strict FP64 behavior with `--fmad=false`. Fast math is not enabled because changing floating-point results changes the proof-of-work hash.

## Verified hardware

RTX 3080 (`sm_86`) has been tested with CUDA 12.4. The development benchmark reached approximately 0.99 MH/s median with peaks above 1.03 MH/s using 128 threads per block. Results depend on clocks, power limit, temperature and driver state.


## Build without CUDA

```bash
cmake -S native -B build/native -DPEPEPOW_ENABLE_CUDA=OFF -DPEPEPOW_BUILD_TESTS=ON
cmake --build build/native --config Release --parallel
ctest --test-dir build/native -C Release --output-on-failure
```

## Build with CUDA

```bash
cmake -S native -B build/native-cuda -DPEPEPOW_ENABLE_CUDA=ON -DPEPEPOW_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build/native-cuda --config Release --parallel
ctest --test-dir build/native-cuda -C Release --output-on-failure
```

## HiveOS / Linux profiling

RTX 3080:

```bash
cd native
chmod +x scripts/profile_cuda.sh
./scripts/profile_cuda.sh 86
ctest --test-dir build-cuda-sm86 --output-on-failure
./build-cuda-sm86/pepepow_cuda_benchmark 1048576 0 128
```

## Included executables

- `pepepowminer` — native application foundation
- `pepepow_cuda_benchmark` — CUDA throughput measurement
- `pepepow_cuda_warp_probe` — warp-divergence and nonlinear branch diagnostic tool

## Current limitations

v0.1.0 is a foundation release. It is not yet a complete pool-connected production miner and does not claim SRBMiner-level performance. Stratum networking, production share submission, long-running device management and additional GPU-specific tuning remain under development.

## Safety

Run mining software only on hardware you own or are explicitly authorized to use. Monitor temperature, power consumption and system stability.

## License

MIT License. See `LICENSE`.
