# PepeW Miner v1.0.4

Universal multi-GPU release for HiveOS. The HooHash V110 `service768` CUDA kernel is retained, while the runtime wrapper now launches one isolated worker per NVIDIA GPU and aggregates all device telemetry.

## Multi-GPU architecture

- one `pepepowminer` process per selected NVIDIA GPU;
- one passive Stratum proxy per GPU on a unique local port;
- GPU selection by NVIDIA UUID through `CUDA_VISIBLE_DEVICES`;
- independent diagnostic/status directory for every GPU;
- fail-fast shutdown if any worker or proxy exits unexpectedly;
- aggregate total hashrate and Accepted/Rejected counters;
- per-GPU `hs[]`, temperature, fan and PCI bus mapping in HiveOS.

This process-per-GPU model keeps each CUDA context, allocation set and Stratum connection isolated. It also allows the existing single-device CUDA backend to scale safely across mixed and homogeneous rigs.

## Supported NVIDIA generations

The release fat binary is built with CUDA Toolkit 12.8.x and contains:

```text
sm_61   GTX 10 series / Pascal
sm_75   RTX 20 series / Turing
sm_86   RTX 30 series / Ampere
sm_89   RTX 40 series / Ada
sm_120  RTX 50 series / Blackwell
compute_120 PTX for forward compatibility
```

CUDA 12.8.x is intentionally pinned: it adds native `SM_120` compiler support while remaining in the final CUDA major series that supports Pascal and Turing targets.

## HiveOS package identity

```text
Miner name:    PepeW-Miner-v1.0.4-HiveOS
Archive asset: PepeW-Miner-v1.0.4-HiveOS-1.0.4.tar.gz
Archive root:  PepeW-Miner-v1.0.4-HiveOS/
Install path:  /hive/miners/custom/PepeW-Miner-v1.0.4-HiveOS
```

## Telemetry

Each worker writes:

```text
gpu<N>/miner-status.env
```

The HiveOS statistics wrapper aggregates these files into:

```text
khs              total hashrate in kH/s
hs[]             per-GPU hashrate in kH/s
temp[]           per-GPU temperature
fan[]            per-GPU fan percentage
bus_numbers[]    per-GPU PCI bus mapping
ar[]             aggregate Accepted/Rejected counters
```

## Optional device selection

All NVIDIA GPUs are enabled by default. To select specific HiveOS/NVIDIA indices, define:

```text
PEPEW_DEVICES=0,2,3
```

The wrapper uses GPU UUIDs internally, avoiding ambiguity when CUDA and `nvidia-smi` enumeration order differ.

## Build requirements

```text
CUDA Toolkit: 12.8.x
CMake:         3.24 or newer
Host OS:       Linux x86_64 / HiveOS
```

Build and package with:

```bash
bash tools/build-v104-universal.sh
```

## Live validation required

Before marking the release final, validate on at least:

- one Pascal/Turing GPU;
- one Ampere/Ada GPU;
- a multi-GPU Blackwell rig;
- Accepted increasing and Rejected remaining zero;
- correct per-GPU HiveOS hashrate mapping;
- no new NVIDIA Xid errors.
