# PepeW Miner v1.0.3

HiveOS integration hotfix for the validated `service768` PEPEPOW HooHash V110 miner.
The CUDA search kernel is unchanged.

## Root causes fixed

1. HiveOS `custom-get` derives the miner directory from the archive filename by
   treating the last hyphen-separated token as the package version.
2. The archive directory must exactly match that derived miner name.
3. `h-config.sh` must expose `miner_ver`, `miner_config_gen`, and
   `miner_config_echo` callbacks expected by `miner-run`.
4. Per-GPU dashboard cards require index-aligned `hs[]`, `temp[]`, `fan[]`, and
   `bus_numbers[]`; `khs` remains the total speed.

## Canonical package identity

```text
Miner name:    PepeW-Miner-v1.0.3-HiveOS
Archive asset: PepeW-Miner-v1.0.3-HiveOS-1.0.3.tar.gz
Archive root:  PepeW-Miner-v1.0.3-HiveOS/
Install path:  /hive/miners/custom/PepeW-Miner-v1.0.3-HiveOS
```

## Telemetry

The stats wrapper explicitly reports `hs_units: khs`, maps PCI bus IDs to decimal
HiveOS bus numbers, and retains total speed, uptime and Accepted/Rejected shares.

## Binary identity

```text
PepeW Miner v1.0.3 | PEPEPOW HooHash V110 | service768 | HiveOS sm_86
```

## Binary SHA256

```text
64d8922d764e74a6a99b800b381c82f0f599292187e4f17214250f274da2f82a
```

## Validation gates

```text
binary identity:             PASS
shell syntax:                PASS
miner_ver callback:          PASS
miner_config_gen callback:   PASS
miner_config_echo callback:  PASS
one-GPU telemetry:           PASS
custom-get parsed miner:     PepeW-Miner-v1.0.3-HiveOS
custom-get parsed version:   1.0.3
archive root:                PASS
manual extraction:           PASS
```
