# PepeW Miner

CUDA miner for PEPEPOW HooHash V110 with HiveOS integration.

## Current prerelease

```text
v0.4.1-PR
```

The short `-PR` suffix keeps the custom miner name readable in the HiveOS desktop and mobile interfaces.

## v0.4.1-PR highlights

- validated HooHash V110 consensus path;
- live pool target derived from each job's `nBits` and Stratum difficulty;
- ASCII-safe colored Hive Shell interface;
- BLAKE3 Header80 first-block midstate optimization;
- pool target comparison directly on the GPU;
- persistent CUDA result allocation;
- optional exact matrix lookup cache for the dominant linear HooHash path;
- configurable CUDA byte-loop unroll factor;
- RTX 3080 launch/register profile benchmarking before packaging;
- selected profile recorded in `BUILD_PROFILE`;
- per-GPU HiveOS hashrate array;
- matching temperature, fan and PCI bus arrays;
- native rolling hashrate telemetry;
- atomic `miner-status.env` state for HiveOS;
- real miner PID tracking and uptime;
- proxy protocol traffic isolated from the visible miner console;
- exact known-chain, live and deterministic CPU/CUDA validation vectors;
- current-run accepted and rejected counters;
- one-command forensic collection.

## Terminal identity

```text
=========================================
              PepeW Miner
=========================================

Version   : v0.4.1-PR
Algorithm : HooHash V110
GPU 0     : NVIDIA CUDA

"PepeW - твоя монета. Твои правила."

=========================================
```

Runtime records use terminal-safe labels:

```text
[POOL] Connected
[READY] Pool authorization complete
[JOB] new work
[MINING] GPU0 1.250 MH/s | A 25 | R 0 | Uptime 00:03:15
[ACCEPTED] share accepted
```

## HiveOS telemetry

`h-stats.sh` reports one entry per active mining device:

- `hs` and `hs_units` for per-GPU speed;
- `temp` for GPU temperature;
- `fan` for fan percentage;
- `bus_numbers` for stable mapping to the HiveOS GPU row;
- total `khs`, uptime, accepted and rejected shares.

The runtime status schema separates `GPU0_HPS`, allowing later multi-GPU expansion without changing the HiveOS data format.

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
