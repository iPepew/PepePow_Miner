# PepeW Miner v1.0.3

HiveOS integration hotfix for the validated `service768` PEPEPOW HooHash V110 miner.
The CUDA search kernel is unchanged.

## Confirmed root causes

1. HiveOS `custom-get` derives the miner directory from the archive filename by
   treating the last hyphen-separated token as the package version.
2. The archive directory must exactly match that derived miner name.
3. HiveOS itself owns the generic dispatcher files in `/hive/miners/custom/`:
   `h-manifest.conf`, `h-config.sh`, `h-run.sh`, and `h-stats.sh`.
4. The generic dispatcher sources the selected package `h-config.sh`; therefore
   package `h-config.sh` must generate `config.txt` immediately when sourced.
5. Per-GPU dashboard cards require index-aligned `hs[]`, `temp[]`, `fan[]`, and
   `bus_numbers[]`; `khs` remains the total speed.

## Canonical package identity

```text
Miner name:    PepeW-Miner-v1.0.3-HiveOS
Archive asset: PepeW-Miner-v1.0.3-HiveOS-1.0.3.1.tar.gz
Archive root:  PepeW-Miner-v1.0.3-HiveOS/
Install path:  /hive/miners/custom/PepeW-Miner-v1.0.3-HiveOS
```

Asset revision `1.0.3.1` supersedes the first wrapper package while the miner
binary version remains `1.0.3`.

## Integration changes

- package `h-config.sh` now creates configuration immediately when sourced by
  the stock HiveOS custom dispatcher;
- package paths are resolved from `BASH_SOURCE[0]`, avoiding accidental writes
  into `/hive/miners/custom/` itself;
- package `h-run.sh` no longer relies on an unexported generic `MINER_DIR`;
- runtime configuration is written atomically with mode `0600`;
- runtime logs are stored under `/var/log/miner/custom/PepeW-Miner-v1.0.3-HiveOS/`;
- stats report explicit `hs_units: khs` and aligned GPU telemetry arrays.

## Required HiveOS system files

These files must remain present on the rig and are not part of the PepeW Miner
archive:

```text
/hive/miners/custom/h-manifest.conf
/hive/miners/custom/h-config.sh
/hive/miners/custom/h-run.sh
/hive/miners/custom/h-stats.sh
/hive/miners/custom/custom-get
```

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
package config generation:   PASS
one-GPU telemetry:           PASS
custom-get parsed miner:     PepeW-Miner-v1.0.3-HiveOS
custom-get parsed version:   1.0.3.1
archive root:                PASS
manual extraction:           PASS
```
