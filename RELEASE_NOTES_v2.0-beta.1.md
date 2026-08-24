# PepeW-Miner-v2.0 BETA

Первая beta-версия новой линейки PepeW Miner v2.x для NVIDIA Tesla V100 / Volta (`sm_70`).

## Основа релиза

Beta построена на проверенном share-producing V100 пути `geometry736/service736`, который на Tesla V100-SXM2-16GB показал реальную работу на пуле:

- средний хешрейт: **4.072 MH/s**;
- диапазон: **4.051–4.114 MH/s**;
- Accepted: **75**;
- Rejected: **0**;
- статус: **PASS**.

## Что входит

- native CUDA `sm_70` для Tesla V100 / Volta;
- HooHash V110;
- проверенное pool/consensus поведение линии v1.0.4;
- профиль V100 `service736`;
- `threads=736`;
- HiveOS package;
- HiveOS Accepted / Rejected telemetry;
- профессиональный интерфейс PepeW Miner;
- фирменная строка `PepeW — твоя монета. Твои правила.`

## HiveOS

Install URL после публикации:

`https://github.com/iPepew/PepePow_Miner/releases/download/v2.0-beta.1/PepeW-Miner-HiveOS.tar.gz`

Algorithm: `hoohash`

Coin: `PEPEW`

## Статус

Это **BETA**. Стабильная `PepeW-Miner-v2.0` будет опубликована только после отдельной проверки именно beta-пакета на Tesla V100 с реальными Accepted shares и приемлемым Reject rate.

Дальнейшая цель разработки: повышение производительности Tesla V100 к **30 MH/s** без потери consensus correctness и реальных Accepted shares.
