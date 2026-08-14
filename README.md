# PepeW Miner

**PepeW Miner — Performance & Stability Edition**

> PepeW — твоя монета. Твои правила.

CUDA-майнер PEPEPOW HooHash V110 с интеграцией HiveOS. Ветка `v1.1.0` сфокусирована на NVIDIA Tesla V100 / Volta `sm_70` и вводит новый HooHash execution model вместо дальнейшей настройки старого service-kernel.

## Current development release

```text
PepeW Miner v1.1.0
```

`v1.1.0` — experimental V100 pre-release. Новый `warp-cohort` kernel работает рядом с проверенным exact-kernel из v1.0.9. На первом старте физический autotuner сравнивает их и автоматически оставляет exact fallback, если новый engine не даёт убедительного прироста.

## Проверенная история Tesla V100

Физические тесты на Tesla V100-SXM2-16GB:

| Версия / профиль | Средний хешрейт | Итог |
|---|---:|---|
| v1.0.5 test1 | ~3.10 MH/s | первый Volta baseline |
| v1.0.5 test2 | ~1.51 MH/s | direct exact, откат |
| v1.0.5 test3 | 5.801 MH/s | service3 |
| v1.0.5 test4 | **6.094 MH/s** | лучший подтверждённый pool baseline |
| v1.0.7 | 0.673 MH/s | async mailbox, откат |
| v1.0.8 | 5.476 MH/s | fast exp/rsqrt, откат |
| v1.0.9 | **5.871 MH/s** | официальный 600-секундный pool test |

v1.0.9 дополнительно подтвердил:

- 619/619 GPU candidates совпали с CPU reference;
- `exact / 768 threads` оказался лучшим из block-geometry sweep;
- fasttrig оказался медленнее exact;
- изменение geometry само по себе не преодолевает ~6 MH/s потолок текущего service execution model.

Поэтому v1.1.0 меняет именно способ исполнения HooHash.

## v1.1.0: Persistent Warp Cohort

В старом `service24` редкие nonlinear-задачи уплотняются хорошо, но CUDA block синхронизируется на каждом matrix cell. В direct exact отсутствуют эти block-wide barriers, но редкие `sin/sincos/exp/sqrt` создают тяжёлую warp divergence.

`warp-cohort` использует третью схему:

```text
warp = 32 независимых nonce state machines

warm lane  -> продолжает дешёвые matrix cells
cold lane  -> сохраняет exact nonlinear input и временно паркуется
             ↓
несколько cold lanes накопились
             ↓
nonlinear cohort выполняется плотной группой
             ↓
каждый nonce продолжает строго со своего следующего cell
```

Основные свойства нового kernel:

```text
threads/block:            256
persistent grid:          yes
hot-loop block barriers:  0
shared task queue:         no
shared atomics:            no
shared memory:             0
GPU math:                  FP64 consensus path
CPU candidate validation:  exact
```

CI `ptxas` для нового Volta kernel:

```text
Registers/thread: 128
Stack:            192 bytes
Spill stores:     0
Spill loads:      0
Barriers:         0
Shared:           0
Local:            0
```

Проверенный exact-kernel остаётся в том же бинарнике как safety fallback.

## V100 physical autotune

Первый запуск на V100 сравнивает:

```text
exact:  768 threads
cohort: 256 threads
```

Для cohort проверяются пороги накопления nonlinear lanes:

```text
4 8 12 16 20 24 28 32
```

и persistent grid density:

```text
1 2 4 8 10 12 blocks/SM
```

Каждый профиль перед benchmark обязан пройти **64 CPU ↔ GPU HooHash nonce comparisons**.

Benchmark использует batch:

```text
1,228,800 nonce
3 timed rounds
median H/s
```

Чтобы экспериментальный kernel не заменил рабочий exact-код из-за шума benchmark, cohort автоматически выбирается только если он быстрее exact минимум на 2%.

Если exact baseline не проходит consensus validation, v1.1.0 работает по fail-closed политике и не начинает майнинг.

Результат autotune кэшируется по UUID физической GPU и SHA256 бинарника.

## Correctness

v1.1.0 не меняет consensus-математику ради заявленного хешрейта:

- FP64 HooHash сохраняется;
- selector и SW state сохраняют exact logic;
- `fmad=false` остаётся включённым;
- parked nonce не переходит к следующему matrix cell до завершения собственной nonlinear-операции;
- каждый autotune profile проверяется CPU reference до измерения скорости;
- каждый найденный GPU share candidate повторно проверяется CPU перед отправкой в pool.

Хешрейт нового cohort engine **не заявляется до физического теста на Tesla V100**.

Цель разработки:

```text
30 MH/s on Tesla V100
```

## HiveOS package

```text
Miner name:       PepeW-Miner-v1.1.0
Archive asset:    PepeW-Miner-v1.1.0-HiveOS.tar.gz
Archive root:     PepeW-Miner-v1.1.0/
Install path:     /hive/miners/custom/PepeW-Miner-v1.1.0
Algorithm:        hoohash
Wallet template:  %WAL%.%WORKER_NAME%
Password:         x
```

После публикации release:

```text
https://github.com/iPepew/PepePow_Miner/releases/download/v1.1.0/PepeW-Miner-v1.1.0-HiveOS.tar.gz
```

## Console design

Стартовая идентификация сохранена:

```text
PepeW Miner v1.1.0 - Performance & Stability Edition
PepeW - твоя монета. Твои правила.
```

Runtime console остаётся компактной:

- без большого ASCII-art;
- без декоративного флага;
- без emoji в событиях;
- `[POOL]`, `[JOB]`, `[ACCEPTED]`, `[REJECTED]`, `[ERROR]`;
- GPU model, `sm`, engine, profile, threads, cohort threshold, blocks/SM и chunk;
- hashrate, temperature, power, clocks, A/R и efficiency;
- без wallet/password в выводе.

## Multi-GPU

HiveOS сохраняет process-per-GPU модель:

- отдельный miner process;
- отдельный local Stratum proxy;
- выбор GPU по UUID через `CUDA_VISIBLE_DEVICES`;
- отдельные PID/log/status;
- агрегированная HiveOS telemetry.

Ограничение GPU:

```text
PEPEW_DEVICES=0,2,3
```

## Build gates

Release candidate собирается GitHub Actions на CUDA Toolkit 12.8.1 для `sm_70`. CI проверяет:

- наличие Volta cubin в финальном miner ELF;
- наличие `header80_pow_warp_cohort_kernel`;
- отсутствие spill/shared/local в cohort kernel;
- clean generated CUDA source без NUL bytes;
- shell syntax HiveOS wrapper/autotuner;
- manifest/package-root consistency;
- SHA256 бинарника;
- отсутствие `__pycache__` и временного мусора в archive.

## Safety

Запускайте майнинг только на оборудовании, которым вы владеете или имеете право пользоваться. Контролируйте температуру, питание и стабильность системы.

## License

MIT License. See [`LICENSE`](LICENSE).
