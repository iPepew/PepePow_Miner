# PepeW Miner

CUDA-майнер PEPEPOW HooHash V110 с интеграцией HiveOS.

## Current development release

```text
PepeW Miner v1.0.4
```

Версия `v1.0.4` добавляет настоящий multi-GPU режим: для каждой выбранной NVIDIA
карты запускается отдельный `pepepowminer` и отдельный локальный Stratum-прокси.
HiveOS получает общий хешрейт и хешрейт каждой карты отдельно.

## Поддерживаемые поколения NVIDIA

Универсальный fat binary собирается CUDA Toolkit 12.8.x и содержит:

```text
sm_61   GTX 10 series / Pascal
sm_75   RTX 20 series / Turing
sm_86   RTX 30 series / Ampere
sm_89   RTX 40 series / Ada
sm_120  RTX 50 series / Blackwell
compute_120 PTX
```

CUDA 12.8.x используется намеренно: эта версия добавляет нативную поддержку
`SM_120` и одновременно остаётся в CUDA 12.x, где ещё доступны Pascal и Turing.

## Multi-GPU

- все NVIDIA GPU включены по умолчанию;
- выбор выполняется по UUID через `CUDA_VISIBLE_DEVICES`;
- каждому GPU назначается отдельный CUDA-контекст и локальный proxy port;
- статусы записываются в `gpu<N>/miner-status.env`;
- `h-stats.sh` суммирует общий хешрейт и Accepted/Rejected;
- `hs[]`, `temp[]`, `fan[]` и `bus_numbers[]` синхронизированы по GPU.

Для ограничения списка карт можно задать:

```text
PEPEW_DEVICES=0,2,3
```

## HiveOS package

```text
Miner name:       PepeW-Miner-v1.0.4-HiveOS
Installation URL: https://github.com/iPepew/PepePow_Miner/releases/download/v1.0.4/PepeW-Miner-v1.0.4-HiveOS-1.0.4.tar.gz
Algorithm:        hoohash
Wallet template:  %WAL%.%WORKER_NAME%
Pool:             stratum+tcp://stratum-eu.pepepow.foztor.net:13232
Password:         x
```

Архив должен содержать верхний каталог:

```text
PepeW-Miner-v1.0.4-HiveOS/
```

Штатные файлы `/hive/miners/custom/h-manifest.conf`, `h-config.sh`, `h-run.sh`
и `h-stats.sh` принадлежат HiveOS и не должны удаляться.

## Сборка

Требования:

```text
Linux x86_64 / HiveOS
CUDA Toolkit 12.8.x
CMake 3.24+
```

Команда:

```bash
bash tools/build-v104-universal.sh
```

Скрипт собирает CUDA fat binary, запускает тесты, проверяет архитектуры,
проверяет multi-GPU telemetry и создаёт готовый HiveOS-архив с SHA256.

Подробности: [`RELEASE_NOTES_v1.0.4.md`](RELEASE_NOTES_v1.0.4.md).

## Safety

Запускайте майнинг только на оборудовании, которым вы владеете или имеете право
пользоваться. Контролируйте температуру, питание и стабильность системы.

## License

MIT License. See [`LICENSE`](LICENSE).
