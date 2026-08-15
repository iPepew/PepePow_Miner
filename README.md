# PepeW Miner

**PepeW Miner — Performance & Stability Edition**

> PepeW — твоя монета. Твои правила.

CUDA-майнер PEPEPOW HooHash V110 с интеграцией HiveOS. Текущая экспериментальная ветка `v1.2.0` сфокусирована на NVIDIA Tesla V100 / Volta `sm_70` и вводит speculative `Magic LUT` solver с обязательной CPU-проверкой share-кандидатов.

## Current development release

```text
PepeW Miner v1.2.0
```

## Проверенная история Tesla V100

Физические результаты на Tesla V100-SXM2-16GB:

| Версия / профиль | Средний хешрейт | Итог |
|---|---:|---|
| v1.0.5 test1 | ~3.10 MH/s | первый Volta baseline |
| v1.0.5 test2 | ~1.51 MH/s | direct exact, откат |
| v1.0.5 test3 | 5.801 MH/s | service3 |
| v1.0.5 test4 | **6.094 MH/s** | лучший подтверждённый pool baseline |
| v1.0.7 | 0.673 MH/s | async mailbox, откат |
| v1.0.8 | 5.476 MH/s | fast exp/rsqrt, откат |
| v1.0.9 | **5.871 MH/s** | официальный 600-секундный pool test |
| v1.1.0 | ~5.86–5.87 MH/s live | cohort autotune снова выбрал exact |

v1.1.0 физически подтвердил, что дальнейший tuning service/geometry/cohort сам по себе не выводит текущий exact execution family из области примерно 6 MH/s.

## v1.2.0: Magic LUT Solver

Новый V100 engine сохраняет exact HooHash selector, exact SW state, FP64 accumulation, BLAKE3 и CPU share validation, но меняет самые дорогие periodic nonlinear branches.

### Periodic nonlinear LUT

Вместо large-argument `sin/sincos/exp` на каждом cold-cell GPU использует две периодические FP64 таблицы:

```text
f0(theta) = exp(sin(theta) + cos(theta))
f1(theta) = sin(theta)^2
```

Каждая таблица имеет 65,536 узлов. Узел хранит `value + derivative`, поэтому между узлами используется cubic-Hermite interpolation.

Общий размер двух таблиц — около 2 MiB.

### Direct phase extraction

Для больших аргументов `2^31 <= |y| < 2^57` периодическая фаза извлекается напрямую из fixed-point умножения mantissa × 128-bit `2/pi`.

Это позволяет избежать формирования общего large-argument floating-point remainder перед trig evaluation.

Для значений вне ограниченного диапазона остаётся стандартный CUDA double math fallback.

### Warm path

Magic engine не использует 512-KiB scaled-nibble lookup для warm-cells. Вместо этого:

```text
32-KiB scaled matrix in constant memory
+
FP64 multiply by nibble
```

Это уменьшает lookup footprint и лучше использует сильный FP64 V100.

### Optional fast rsqrt

Третий nonlinear region autotuner проверяет в двух режимах:

```text
exact 1/sqrt()
FP32 rsqrt seed + 1 FP64 Newton step
```

## Autotune считает effective rate

Для exact baseline требуется 100% CPU/GPU совпадений.

Для Magic профилей перед benchmark выполняются 256 deterministic CPU↔GPU full-HooHash comparisons.

Главная метрика:

```text
effective_hps = raw_hps × exact_hash_quality
```

Поэтому большой raw MH/s сам по себе не считается успехом.

Проверяются:

```text
threads:       128, 256
blocks/SM:     1, 2, 4, 6, 8
fast_rsqrt:    0, 1
batch:         1,228,800
rounds:        3
min quality:   90%
```

Magic выбирается только если его effective rate минимум на 5% превосходит exact baseline. Иначе miner автоматически остаётся на exact service768.

## Candidate safety

Каждый найденный GPU share candidate повторно пересчитывается точным CPU HooHash. Share отправляется в pool только если:

```text
GPU hash == CPU hash
CPU hash meets target
```

Это позволяет экспериментировать со speculative GPU solver без отправки заведомо неправильных shares.

## Batch policy

```text
exact: 262,144 nonce
magic: 1,228,800 nonce
```

Большой Magic batch используется только после победы профиля на физическом autotune.

## HiveOS package

```text
Miner name:       PepeW-Miner-v1.2.0
Archive asset:    PepeW-Miner-v1.2.0-HiveOS.tar.gz
Archive root:     PepeW-Miner-v1.2.0/
Install path:     /hive/miners/custom/PepeW-Miner-v1.2.0
Algorithm:        hoohash
Wallet template:  %WAL%.%WORKER_NAME%
Password:         x
```

Release URL после публикации:

```text
https://github.com/iPepew/PepePow_Miner/releases/download/v1.2.0/PepeW-Miner-v1.2.0-HiveOS.tar.gz
```

## Console design

```text
PepeW Miner v1.2.0 - Performance & Stability Edition
PepeW - твоя монета. Твои правила.
```

Console остаётся компактной и ASCII-safe:

- без большого ASCII-art;
- без флага;
- без emoji runtime events;
- без wallet/password;
- `[POOL]`, `[JOB]`, `[ACCEPTED]`, `[REJECTED]`, `[ERROR]`;
- engine, profile, threads, blocks/SM, rsqrt mode, quality, raw/effective tune rate и chunk;
- hashrate, temperature, power, clocks, A/R и efficiency.

## Multi-GPU

HiveOS сохраняет process-per-GPU модель с отдельным local Stratum proxy, PID/log/status и выбором GPU через UUID.

```text
PEPEW_DEVICES=0,2,3
```

## Build / correctness gates

CI для v1.2.0 проверяет:

- CUDA Toolkit 12.8.1 / `sm_70`;
- Volta cubin в финальном miner ELF;
- наличие exact и `header80_pow_magic_kernel`;
- resource usage нового kernel;
- core tests;
- shell syntax HiveOS integration;
- manifest/package-root consistency;
- SHA256;
- отсутствие временного мусора в archive.

До физического теста **v1.2.0 не заявляет новый V100 hashrate**.

Цель разработки остаётся:

```text
30 MH/s on Tesla V100
```

## Safety

Запускайте майнинг только на оборудовании, которым вы владеете или имеете право пользоваться. Контролируйте температуру, питание и стабильность системы.

## License

MIT License. See [`LICENSE`](LICENSE).
