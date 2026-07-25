# PepePow Miner v0.1.1-rc1

Release candidate for the first pool-capable PEPEPOW/HooHash V110 miner.

## Implemented

- Stratum V1 subscribe, authorize, difficulty and notify handling.
- Coinbase and merkle-root reconstruction.
- Canonical 80-byte PEPEPOW block-header construction.
- CPU reference HooHash V110 validation path.
- PEPEPOW pool-difficulty to 256-bit target conversion.
- CPU reference nonce search for correctness testing.
- HiveOS launcher, configuration script and manifest.

## Test target

- NVIDIA GeForce RTX 3080
- Linux / HiveOS
- CUDA architecture sm_86

## Release blocker

The production CUDA direct-header search path must be validated on RTX 3080 and must produce accepted pool shares before the final v0.1.1 tag and binary archive are published.

This release candidate must not be described as a finished mining binary until that validation is complete.
