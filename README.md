# PepeW Miner

CUDA-майнер PEPEPOW HooHash V110 с интеграцией HiveOS.

## Stable release

```text
PepeW Miner v1.0.0
```

Релиз 1.0 использует архитектуру `service768`: редкие тяжёлые nonlinear-операции HooHash уплотняются внутри CUDA-блока и выполняются выделенным service warp. Это устраняет основную потерю производительности от warp divergence.

## Подтверждённая производительность RTX 3080

Реальный 10-минутный Stratum-тест при 1650 MHz:

```text
mean:       2.023649 MH/s
median:     2.022 MH/s
accepted:   90
rejected:   0
new Xid:    0
live gate:  PASS
2 MH gate:  PASS
```

Локальная проверка финального ядра:

```text
benchmark median:  2.204878 MH/s
stress median:     2.209934 MH/s
registers:         77
stack:             176 B
spills:             0 / 0
compute-sanitizer: PASS
consensus:         PASS
```

Подробности: [`RELEASE_NOTES_v1.0.0.md`](RELEASE_NOTES_v1.0.0.md).

## Основные изменения 1.0

- block-compacted HooHash cold-service;
- проверенная CUDA-геометрия 768 потоков;
- точный объединённый FP64 selector decoder;
- точный bit-level SW-state predicate;
- cell-major scaled-nibble lookup table;
- BLAKE3 Header80 midstate;
- GPU-side target filter;
- CPU-проверка каждой найденной шары перед отправкой;
- `--fmad=false` для сохранения точного FP64-консенсуса;
- полноценная HiveOS-телеметрия и Accepted/Rejected.

## Поддерживаемая платформа

Первичный бинарный релиз собран для:

```text
Linux x86_64
NVIDIA Ampere sm_86
RTX 30 series
HiveOS
```

Оптимизация и live-проверка выполнены на RTX 3080. Другие CUDA-архитектуры требуют отдельной сборки и валидации.

## Сборка финального HiveOS-пакета

На тестовом риге должен быть пустой полётный лист. Сборщик не меняет частоты и не заменяет установленный майнер.

```bash
curl -fsSL https://raw.githubusercontent.com/iPepew/PepePow_Miner/release/v1.0.0/tools/start-v100-release-build.sh | bash
```

Процедура выполняет:

1. проверку SHA256 точного consensus-tested CUDA-исходника;
2. Release-сборку `service768` для `sm_86`;
3. CTest и CPU/CUDA consensus validation;
4. проверку PTXAS-регистров и отсутствия spills;
5. benchmark с обязательной медианой не ниже 2 MH/s;
6. `compute-sanitizer`, когда он доступен;
7. проверку новых NVIDIA Xid;
8. создание отдельного HiveOS-архива и `.sha256`.

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

Дополнительные аргументы майнера не требуются.

## Terminal identity

```text
=========================================
            PepeW Miner
=========================================

Version   : v1.0.0
Algorithm : HooHash V110
GPU       : NVIDIA CUDA

"PepeW — твоя монета. Твои правила."
=========================================
```

## Safety

Запускайте майнинг только на оборудовании, которым вы владеете или имеете право пользоваться. Контролируйте температуру, питание и стабильность системы.

## License

MIT License. See [`LICENSE`](LICENSE).
