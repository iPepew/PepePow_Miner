# PepeW Miner 1.0.0

Первый полноценный стабильный релиз CUDA-майнера PEPEPOW HooHash V110.

## Подтверждённый результат RTX 3080

Финальный профиль `service768` проверен 3 августа 2026 года на реальном Stratum-пуле при фиксированной частоте ядра 1650 MHz:

| Показатель | Результат |
|---|---:|
| Средний live-хешрейт | **2.023649 MH/s** |
| Медианный live-хешрейт | **2.022 MH/s** |
| Диапазон live-замеров | 1.994–2.048 MH/s |
| Accepted | **90** |
| Rejected | **0** |
| Новые NVIDIA Xid | **0** |
| Средняя мощность | 86.16 W |
| Средняя температура | 46.91 °C |

Итоговые автоматические шлюзы:

```text
smoke_gate=PASS
LIVE_GATE=SMOKE_PASS
TARGET_2MH=LIVE_SMOKE_PASS
```

SHA256 архива с доказательствами live-теста:

```text
2fda5617b01757cdfee2169aac41fa2d8a243ab5394bd3fff3478b1130d6fd69
```

## Архитектура 1.0

- block-compacted cold-service для редких HooHash nonlinear-операций;
- один service warp обрабатывает уплотнённую очередь `sin/cos/exp/sqrt`;
- CUDA-блок на 768 потоков для RTX 30 / Ampere SM 8.6;
- точный объединённый FP64 selector decoder;
- точный bit-level SW-state predicate;
- cell-major scaled-nibble lookup table;
- BLAKE3 Header80 midstate и GPU-side target filter;
- FP contraction отключён (`--fmad=false`) для сохранения консенсуса;
- CPU повторно проверяет каждую найденную GPU-шару перед отправкой.

## Офлайн-валидация

Финальная геометрия `service768` показала:

```text
benchmark median:  2.204878 MH/s @ 1650 MHz
stress median:     2.209934 MH/s
registers:         77
stack:             176 B
spill stores:      0
spill loads:       0
compute-sanitizer: PASS
consensus:         PASS
new NVIDIA Xid:    0
```

В live-режиме хешрейт ниже локального benchmark из-за смены заданий, Stratum и рабочей нагрузки майнера; целевой порог 2 MH/s при этом подтверждён средним и медианным live-результатом.

## Поддерживаемая конфигурация релиза

- NVIDIA RTX 30 / compute capability 8.6;
- HiveOS/Linux x86_64;
- CUDA toolkit и совместимый NVIDIA-драйвер;
- PEPEPOW HooHash V110.

Первичный релиз оптимизирован и проверен на RTX 3080. Работа на других архитектурах не заявляется без отдельного тестирования.

## Безопасность релиза

Сборщик релиза не изменяет частоты, Power Limit или прошивку GPU, не устанавливает пакет поверх текущего майнера и не запускает его автоматически. Сначала создаётся отдельный архив HiveOS с SHA256.
