# PepeW Miner

CUDA-майнер PEPEPOW HooHash V110 с нативной интеграцией HiveOS.

## Stable HiveOS package

```text
PepeW Miner v1.0.3
```

Версия `v1.0.3` исправляет полный цикл Custom Miner: имя архива, имя каталога,
callbacks HiveOS и per-GPU telemetry. CUDA-ядро `service768` не изменено.

## Правильная установка HiveOS

```text
Miner name:       PepeW-Miner-v1.0.3-HiveOS
Installation URL: https://github.com/iPepew/PepePow_Miner/releases/download/v1.0.3/PepeW-Miner-v1.0.3-HiveOS-1.0.3.tar.gz
Algorithm:        hoohash
Wallet template:  %WAL%.%WORKER_NAME%
Pool:             stratum+tcp://stratum-eu.pepepow.foztor.net:13232
Password:         x
```

Имя asset содержит дополнительный суффикс `-1.0.3` специально для официального
`custom-get`: последний сегмент считается версией, а оставшаяся часть — именем
каталога custom miner.

## HiveOS callbacks

- `miner_ver` сообщает версию пакета;
- `miner_config_gen` атомарно создаёт `config.txt`;
- `miner_config_echo` показывает конфигурацию без раскрытия кошелька и пароля;
- `h-run.sh` использует стандартный `MINER_DIR`;
- `h-stats.sh` возвращает `khs`, `hs[]`, `hs_units`, `temp[]`, `fan[]`,
  `bus_numbers[]`, uptime и Accepted/Rejected.

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
