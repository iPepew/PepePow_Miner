# PepeW Miner

CUDA miner for PEPEPOW HooHash V110 with HiveOS integration.

## Current prerelease

```text
v0.3.9-PR
```

The short `-PR` suffix keeps the custom miner name readable in the HiveOS mobile interface.

## v0.3.9-PR highlights

- validated HooHash V110 consensus path;
- live pool target derived from each job's `nBits` and Stratum difficulty;
- BLAKE3 Header80 midstate optimization;
- pool target comparison directly on the GPU;
- persistent CUDA result allocation;
- native rolling hashrate telemetry;
- atomic `miner-status.env` state for HiveOS;
- real miner PID tracking and uptime;
- no miner-to-`tee` pipe and no SIGPIPE restart path;
- compact color terminal interface;
- current-run accepted and rejected counters;
- one-command forensic collection.

## Terminal identity

```text
=========================================
            🐸 PepeW Miner 🐸
=========================================

Version   : v0.3.9-PR
Algorithm : HooHash V110
GPU       : NVIDIA CUDA

"PepeW — твоя монета. Твои правила."

=========================================
```

## HiveOS

Pool URL:

```text
stratum+tcp://pool.pepepow.net:39333
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
