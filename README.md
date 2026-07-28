# PepeW Miner

CUDA miner for PEPEPOW HooHash V110 with HiveOS integration.

## Current prerelease

```text
v0.5.0-PR
```

The short `-PR` suffix keeps the custom miner name readable in the HiveOS desktop and mobile interfaces.

## v0.5.0-PR performance architecture

- validated HooHash V110 consensus path;
- word-oriented BLAKE3 first-pass and final-hash pipeline;
- BLAKE3 Header80 first-block midstate;
- exact 32 KiB scaled-matrix constant cache;
- original matrix retained in a persistent device allocation for nonlinear work;
- cached per-job matrix, midstate and tail uploads;
- cached 256-bit target represented as eight big-endian words;
- compact four-byte result reset and compact winning-result transfer;
- GPU-side target comparison;
- launch-bounds, block-size, unroll and register autotuning;
- 4,194,304-nonce benchmark for every candidate profile;
- 512 deterministic CPU/CUDA validation samples per profile;
- selected profile and PTXAS register/spill data recorded in `BUILD_PROFILE`;
- per-GPU HiveOS hashrate, temperature, fan and PCI bus arrays;
- real PID, uptime and stale-telemetry protection;
- one-command forensic collection.

Strict FP64 operation order remains protected. CUDA is compiled with FP contraction disabled because changing the floating-point result changes the proof-of-work hash.

## Terminal identity

```text
=========================================
              PepeW Miner
=========================================

Version   : v0.5.0-PR
Algorithm : HooHash V110
GPU 0     : NVIDIA CUDA

"PepeW - твоя монета. Твои правила."
Telegram  : https://t.me/pepepow_ru

=========================================
```

Runtime records use terminal-safe labels:

```text
[POOL] Connected
[READY] Pool authorization complete
[JOB] new work
[MINING] GPU0 2.000 MH/s | A 25 | R 0 | Uptime 00:03:15
[ACCEPTED] share accepted
```

## RTX 3080 mega-autotune

The dedicated v0.5.0 builder validates and measures several launch profiles. It varies:

- 64 versus 128 threads per block;
- one versus two requested resident blocks per SM;
- exact scaled-matrix cache enabled versus disabled;
- byte-loop unroll factor;
- automatic versus limited register allocation.

The fastest exact profile is packaged automatically. The builder reports whether the measured local benchmark reaches the 2 MH/s engineering target; package creation is never allowed to bypass consensus validation.

## HiveOS telemetry

`h-stats.sh` reports one aligned entry per active mining device:

- `hs` and `hs_units` for per-GPU speed;
- `temp` for GPU temperature;
- `fan` for fan percentage;
- `bus_numbers` for stable mapping to the HiveOS GPU row;
- total `khs`, uptime, accepted and rejected shares.

## HiveOS

Pool URL:

```text
stratum+tcp://stratum-eu.pepepow.foztor.net:13232
```

Wallet template:

```text
%WAL%.%WORKER_NAME%
```

Password:

```text
x
```

No additional miner arguments are required.

## Safety

Run mining software only on hardware you own or are explicitly authorized to use. Monitor temperature, power consumption and system stability.

## License

MIT License. See `LICENSE`.
