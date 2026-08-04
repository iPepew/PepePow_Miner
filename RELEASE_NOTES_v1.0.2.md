# PepeW Miner v1.0.2 — HiveOS per-GPU telemetry fix

PepeW Miner v1.0.2 is a HiveOS integration release for the validated
`service768` PEPEPOW HooHash V110 engine. The CUDA mining code is unchanged;
the package identity and HiveOS telemetry wrapper are updated.

## Fixed

- per-GPU hashrate is emitted through HiveOS `hs[]` telemetry in kH/s;
- the scalar shell variable `khs` remains the total miner hashrate;
- `hs[]`, `temp[]`, `fan[]` and `bus_numbers[]` use the same GPU index;
- PCI bus IDs such as `02:00.0` map telemetry to the correct GPU row;
- aggregate HPS fallback is used only on a single-GPU rig, preventing a total
  multi-GPU rate from being incorrectly assigned to GPU 0;
- GPU count uses the larger valid value reported by the miner status file and
  `nvidia-smi`;
- the status freshness window is increased to 45 seconds to reduce transient
  dashboard gaps.

## Expected HiveOS display

For every active GPU, HiveOS receives the card's own hashrate, temperature,
fan percentage and PCI bus mapping. A single RTX 3080 can therefore appear as:

```text
GPU 0 / 02:00.0 / GeForce RTX 3080
66 C / 71% / 2.518 MH/s
```

For multiple cards, `GPU0_HPS`, `GPU1_HPS`, and subsequent status fields are
mapped to the corresponding `hs[]` entries and PCI bus numbers.

## Validation

The v1.0.2 package self-test requires:

```text
ONE_GPU_HS=[2518]
TWO_GPU_HS=[2518,2000]
TOTAL_KHS_ONE=2518
TOTAL_KHS_TWO=4518
HIVEOS_TELEMETRY_GATE=PASS
PACKAGE_ROOT_CHECK=PASS
```

Core validation inherited from the unchanged v1.0.1 CUDA engine:

- release benchmark median: `2.208874 MH/s`;
- CTest: PASS;
- CPU/CUDA consensus: PASS;
- Compute Sanitizer: PASS;
- CUDA spills: `0 / 0`;
- new NVIDIA Xid: `0`.
