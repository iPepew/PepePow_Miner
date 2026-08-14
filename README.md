# PepeW Miner

**PepeW Miner — Performance & Stability Edition**

> PepeW — твоя монета. Твои правила.

CUDA-майнер PEPEPOW HooHash V110 с интеграцией HiveOS и отдельной оптимизацией NVIDIA Tesla V100 / Volta `sm_70`.

## Current development release

```text
PepeW Miner v1.0.9
```

`v1.0.9` — V100-first pre-release. Его главная задача — уйти от фиксированной геометрии CUDA-блока и автоматически подобрать на физической Tesla V100 лучший из двух движков и лучший размер блока перед запуском майнинга.

## Что изменилось в v1.0.9

### Dual-engine V100 autotune

В пакет входят два HooHash CUDA-движка:

```text
exact
fasttrig
```

`exact` сохраняет проверенный FP64 service-path и стандартные CUDA `sin/sincos/exp/sqrt`.

`fasttrig` сохраняет HooHash FP64, selector и CPU validation, но для реального диапазона больших аргументов HooHash выполняет собственную ограниченную редукцию аргумента перед `sincos()`. Это позволяет избежать общего медленного пути CUDA для больших double-аргументов, не заменяя сам `sincos()` низкоточной аппроксимацией.

Ни один fasttrig-профиль не выбирается только по скорости. Перед измерением производительности каждый профиль обязан пройти CPU/GPU HooHash validation.

### Полный sweep block geometry

Для Tesla V100 автоматически проверяются все кратные 32 размеры блока от 96 до 768 потоков:

```text
96 128 160 192 224 256 288 320 352 384 416
448 480 512 544 576 608 640 672 704 736 768
```

Для каждого сочетания `engine × threads`:

1. проверяется набор детерминированных nonce CPU против GPU;
2. выполняется warm-up;
3. выполняются три timed benchmark run;
4. выбирается медианный H/s;
5. в майнинг допускаются только consensus-valid варианты.

Победитель кэшируется по UUID GPU и SHA256 обоих бинарников. После обновления бинарника автотюнинг выполняется заново.

### Dynamic shared scratch

В предыдущем `service24` shared scratch всегда резервировался под 768 потоков. В v1.0.9 он зависит от фактического `threads/block`:

```text
shared_bytes = 8 + 28 * threads
```

Это позволяет маленьким CUDA-блокам конкурировать с 768-thread baseline без постоянного расхода ~21 KiB shared memory на каждый блок.

### Volta cache profile

Для основного HooHash kernel используется:

```text
cudaFuncCachePreferL1
PreferredSharedMemoryCarveout = MaxL1
```

Это соответствует compute-bound характеру HooHash и освобождает максимум доступного L1 при сохранении требуемого dynamic shared memory.

## Проверенные V100 результаты до v1.0.9

Физические тесты Tesla V100-SXM2-16GB:

| Версия / профиль | Средний хешрейт | Результат |
|---|---:|---|
| v1.0.5 test1 | ~3.10 MH/s | baseline Volta |
| v1.0.5 test2 | ~1.51 MH/s | direct exact, откат |
| v1.0.5 test3 | 5.801 MH/s | service3 |
| v1.0.5 test4 | **6.094 MH/s** | лучший подтверждённый PepeW baseline |
| v1.0.7 | 0.673 MH/s | async mailbox, откат |
| v1.0.8 | 5.476 MH/s steady | fast exp/rsqrt, откат |

До физического тестирования v1.0.9 никакой новый хешрейт не заявляется.

Цель разработки на Tesla V100 остаётся:

```text
30 MH/s
```

## HiveOS package

```text
Miner name:       PepeW-Miner-v1.0.9
Archive asset:    PepeW-Miner-v1.0.9-HiveOS.tar.gz
Archive root:     PepeW-Miner-v1.0.9/
Install path:     /hive/miners/custom/PepeW-Miner-v1.0.9
Algorithm:        hoohash
Wallet template:  %WAL%.%WORKER_NAME%
Password:         x
```

Release URL после публикации `v1.0.9`:

```text
https://github.com/iPepew/PepePow_Miner/releases/download/v1.0.9/PepeW-Miner-v1.0.9-HiveOS.tar.gz
```

## Первый запуск на V100

При `PEPEPOW_CUDA_THREADS_RUNTIME=auto` HiveOS launcher сначала запускает V100 autotuner. В консоли отображаются только технические результаты профилей — wallet и password не выводятся.

Пример логики:

```text
[AUTOTUNE] mode=exact    threads=256 consensus=PASS benchmark=...
[AUTOTUNE] mode=fasttrig threads=256 consensus=PASS benchmark=...
...
[AUTOTUNE] selected mode=... threads=... benchmark=... MH/s
```

После выбора miner запускается с выбранным engine и block size. Результат сохраняется в `autotune/` внутри каталога майнера.

Повторный принудительный sweep:

```bash
PEPEW_V100_AUTOTUNE_FORCE=1 miner restart
```

## Console design

v1.0.9 сохраняет требования профессиональной HiveOS-консоли:

- без большого ASCII-art логотипа;
- без декоративного флага;
- без emoji в runtime events;
- компактные `[POOL]`, `[JOB]`, `[ACCEPTED]`, `[REJECTED]`, `[ERROR]`;
- модель GPU, `sm`, профиль, выбранный engine, block size и chunk;
- hashrate, temperature, fan, power, core/memory clocks, A/R и efficiency;
- общий hashrate и total power;
- без wallet/password в консоли.

Стартовая идентификация:

```text
PepeW Miner v1.0.9 - Performance & Stability Edition
PepeW - твоя монета. Твои правила.
```

## Correctness gates

v1.0.9 использует несколько уровней защиты:

- CPU reference HooHash остаётся источником истины;
- exact engine сохраняет стандартный double math;
- fasttrig меняет только argument reduction для больших trig-аргументов;
- каждый autotune profile проходит CPU/GPU nonce validation до benchmark;
- если нет consensus-valid профиля, miner не начинает работу;
- каждый найденный GPU share candidate повторно проверяется CPU перед отправкой в pool;
- `fmad=false` сохраняется для consensus-sensitive основного HooHash path.

## Multi-GPU

HiveOS-архитектура остаётся process-per-GPU:

- отдельный `pepepowminer` на каждую выбранную NVIDIA GPU;
- отдельный локальный Stratum proxy на GPU;
- выбор физической карты по UUID через `CUDA_VISIBLE_DEVICES`;
- отдельные логи/PID/status для каждого GPU;
- агрегированная HiveOS telemetry.

Для ограничения устройств:

```text
PEPEW_DEVICES=0,2,3
```

## Build

Release candidate собирается GitHub Actions в CUDA Toolkit 12.8.1 для `sm_70` и проверяется на наличие Volta cubin уже в финальных ELF-файлах, а не только в промежуточном CUDA object.

v1.0.9 является pre-release до завершения физического V100 autotune и длительного pool test.

## Safety

Запускайте майнинг только на оборудовании, которым вы владеете или имеете право пользоваться. Контролируйте температуру, питание и стабильность системы.

## License

MIT License. See [`LICENSE`](LICENSE).
