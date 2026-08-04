# PepeW Miner

CUDA-майнер PEPEPOW HooHash V110 с нативной интеграцией HiveOS.

## Stable HiveOS package

```text
PepeW Miner v1.0.3
```

Версия `v1.0.3` исправляет полный цикл Custom Miner: имя архива, имя каталога,
генерацию конфигурации и per-GPU telemetry. CUDA-ядро `service768` не изменено.

## Правильная установка HiveOS

```text
Miner name:       PepeW-Miner-v1.0.3-HiveOS
Installation URL: https://github.com/iPepew/PepePow_Miner/releases/download/v1.0.3/PepeW-Miner-v1.0.3-HiveOS-1.0.3.1.tar.gz
Algorithm:        hoohash
Wallet template:  %WAL%.%WORKER_NAME%
Pool:             stratum+tcp://stratum-eu.pepepow.foztor.net:13232
Password:         x
```

Asset revision `1.0.3.1` keeps the public miner version at `1.0.3` and prevents
stale GitHub/HiveOS package caches. The final hyphen-separated token is parsed by
HiveOS `custom-get` as the asset version; the remaining filename becomes the
custom miner directory.

## HiveOS integration

- the stock `/hive/miners/custom/` dispatcher remains owned by HiveOS;
- package `h-config.sh` is sourced by that dispatcher and immediately creates
  `config.txt` inside the selected package directory;
- package `h-run.sh` resolves its directory from its own script path;
- `h-stats.sh` returns `khs`, `hs[]`, `hs_units`, `temp[]`, `fan[]`,
  `bus_numbers[]`, uptime and Accepted/Rejected.

The stock dispatcher files `/hive/miners/custom/h-manifest.conf`, `h-config.sh`,
`h-run.sh` and `h-stats.sh` must exist on the rig. They are HiveOS system files,
not files from the PepeW Miner archive.

## Проверенная производительность RTX 3080

```text
release benchmark median: 2.208874 MH/s
CTest:                   PASS
CPU/CUDA consensus:      PASS
Compute Sanitizer:       PASS
CUDA spills:             0 / 0
new NVIDIA Xid:          0
```

## Binary SHA256

```text
64d8922d764e74a6a99b800b381c82f0f599292187e4f17214250f274da2f82a
```

Подробности: [`RELEASE_NOTES_v1.0.3.md`](RELEASE_NOTES_v1.0.3.md).

## Safety

Запускайте майнинг только на оборудовании, которым вы владеете или имеете право
пользоваться. Контролируйте температуру, питание и стабильность системы.

## License

MIT License. See [`LICENSE`](LICENSE).
