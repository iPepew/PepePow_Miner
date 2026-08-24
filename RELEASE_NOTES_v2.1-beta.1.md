# PepeW-Miner-v2.1 BETA

Профессиональное обновление интерфейса консоли для линии Tesla V100 / Volta (`sm_70`).

## Изменения относительно v2.0 BETA

- Полностью убраны emoji из консольного интерфейса майнера.
- Интерфейс переведён на строгие текстовые статусы: `[HOOHASH]`, `[POOL]`, `[READY]`, `[DIFF]`, `[JOB]`, `[ACCEPTED]`, `[REJECTED]`, `[MINING]`, `[ERROR]`.
- Строка майнинга приведена к компактному профессиональному виду: `MH/s | A | R | UP`.
- Сохранена фирменная строка `PepeW — твоя монета. Твои правила.`.
- Исправлено предупреждение HiveOS `./BUILD_PROFILE: No such file or directory`: при отсутствии файла используется безопасный профиль `embedded`.
- HiveOS отображает версию как `v2.1 BETA`.
- Accepted / Rejected передаются в HiveOS как `ar=[accepted,rejected]`.

## Основа майнинга

В этой beta-версии алгоритмическая часть не меняется относительно подтверждённой V100-базы. Используется native CUDA `sm_70`, HooHash V110 и проверенный `service736` путь. Изменения v2.1 BETA в первую очередь относятся к интерфейсу и качеству упаковки.

## Проверенная база Tesla V100

Ранее подтверждённый real-pool результат рабочей V100-базы:

- средний хешрейт: **4.072 MH/s**;
- диапазон: **4.051–4.114 MH/s**;
- Accepted: **75**;
- Rejected: **0**;
- статус: **PASS**.

Новый пакет v2.1 BETA должен пройти отдельный real-pool тест перед переходом в Stable.

## HiveOS Install URL

`https://github.com/iPepew/PepePow_Miner/releases/download/v2.1-beta.1/PepeW-Miner-HiveOS.tar.gz`

Algorithm: `hoohash`

Coin: `PEPEW`
