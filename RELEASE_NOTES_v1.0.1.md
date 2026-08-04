# PepeW Miner v1.0.1

PepeW Miner v1.0.1 is a HiveOS integration and production-runtime hotfix for the verified `service768` CUDA miner.

## Fixed

- HiveOS dashboard hashrate reporting now uses the native custom-miner `khs` schema.
- The total shell variable `khs` and per-GPU JSON array are generated from `HPS` in `miner-status.env`.
- `--diagnostic-log` is always supplied so the binary creates `miner-status.env` inside the installed miner directory.
- A `/tmp/miner-status.env` compatibility fallback is retained for older starts.
- A console-log fallback can recover the latest `[MINING]` hashrate if the status file is temporarily unavailable.
- The HiveOS release archive uses a flat root and installs into `/hive/miners/custom/PepeW-Miner/` without a double-nested directory.
- The manifest configuration path now matches the canonical HiveOS custom-miner directory.
- Unsupported emoji glyphs were replaced with stable ASCII console labels.

## Runtime

- Production batch: `1048576` nonces.
- Engine: `service768`.
- Full per-job diagnostics are disabled by default; CPU verification of every submitted share remains enabled.

## Verified RTX 3080 result

A production run at a fixed 1650 MHz core clock showed approximately `2.12–2.14 MH/s`, accepted shares increasing, and zero rejected shares in the supplied runtime log.

The earlier controlled 10-minute live validation remains:

- mean: `2.023649 MH/s`
- median: `2.022 MH/s`
- accepted: `90`
- rejected: `0`
- new NVIDIA Xid: `0`

## Release gates

The final build process requires:

- version `1.0.1`
- CPU/CUDA consensus validation
- CTest pass
- median benchmark at or above `2.000 MH/s`
- zero CUDA register spills
- Compute Sanitizer pass when available
- zero new NVIDIA Xid
- HiveOS telemetry self-test producing `khs=2137` and `{"khs":[2137]}`
- flat-root HiveOS package layout
- clean package with no wallet, runtime log, PID, or generated configuration files
