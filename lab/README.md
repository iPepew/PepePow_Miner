# PepeW Hardware Lab

This directory contains the hardware-test harness used to validate PepeW Miner builds on real HiveOS GPUs.

## Safety model

Do **not** register a self-hosted runner directly on the public `iPepew/PepePow_Miner` repository. A runner attached to a public repository can execute repository workflow code on the physical rig.

Use a separate **private** repository such as `iPepew/PepePow_Lab` and register the HiveOS rig only there.

## V100 baseline

Current validated baseline on Tesla V100-SXM2-16GB:

- CUDA toolkit: 11.8
- backend: `cuda-header80-cuda118`
- real-block HooHashV110 GPU consensus KAT: PASS
- initial hashrate: about 4.65-4.69 MH/s
- rejected shares during validation: 0
- reconnects during validation: 0

The CPU KAT on HiveOS is not a consensus oracle for HooHashV110 because host `libm` results differ. The GPU startup KAT against the known PEPEPOW block digest is the correctness gate.

## What the harness does

`pepew-hardware-test.sh` performs the following sequence:

1. Stops the current miner.
2. Force-downloads the rolling `hiveos-test` package from GitHub.
3. Reads `BUILD_INFO.txt`.
4. Starts the existing PepeW HiveOS Flight Sheet configuration.
5. Requires `HooHashV110 CUDA consensus self-test: PASS`.
6. Waits for Stratum telemetry to become online.
7. Warms up the GPU.
8. Measures hashrate and samples `nvidia-smi` for the configured duration.
9. Checks hashrate, rejected shares and reconnect thresholds.
10. Writes `report.json`, `gpu.csv`, measured telemetry and a redacted miner log.

The script does not embed or export the wallet, pool password or Flight Sheet configuration.

## Manual test on HiveOS

Run as root:

```bash
PEPEW_TEST_SECONDS=180 \
PEPEW_MIN_MHS=4.50 \
PEPEW_REPORT_DIR=/tmp/pepew-hwtest \
bash ./lab/pepew-hardware-test.sh
```

A successful report looks like:

```json
{
  "status": "PASS",
  "gpu": "Tesla V100-SXM2-16GB",
  "cuda_toolkit": "11.8",
  "consensus_kat": "PASS",
  "hashrate_avg_mhs": 4.68,
  "rejected": 0,
  "reconnects": 0,
  "miner_state": "online"
}
```

Accepted shares are deliberately **not** required for a short hardware test because production pool difficulty can make the expected wait much longer than the test duration.

## Private GitHub Actions runner

In the private lab repository:

1. Copy `lab/pepew-hardware-test.sh` to `scripts/pepew-hardware-test.sh`.
2. Copy `lab/private-runner-workflow.yml.example` to `.github/workflows/v100-hardware-test.yml`.
3. Register the HiveOS machine as a self-hosted Linux runner in that private repository.
4. Add the custom runner label `pepew-v100`.
5. Run the `PepeW V100 Hardware Test` workflow with `workflow_dispatch`.

The workflow uploads the complete test result as a private GitHub Actions artifact and also places `report.json` into the Actions job summary.

## PASS/FAIL gates

Defaults for the validated V100 baseline:

- consensus KAT: must PASS
- final miner state: `online`
- average hashrate: at least 4.50 MH/s
- rejected shares: at most 0
- reconnects: at most 1
- telemetry samples: at least 2

All thresholds can be overridden with environment variables so later optimization branches can use stricter regression gates.
