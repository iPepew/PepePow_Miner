# Статус разработки PepeW v2.x

Обновлено: 30 августа 2026 года.

## Защищённый baseline

`v21-beta1-v100-t704-svc4-realpool` остаётся неизменным и не должен перезаписываться кандидатами:

- средний real-pool хешрейт: 4.335 MH/s;
- диапазон: 4.317–4.345 MH/s;
- шары: A+109/R0;
- средняя мощность: 87.06 W;
- загрузка GPU: 99.97%;
- частота ядра: 1530 MHz;
- частота памяти: 877 MHz.

Лучший ранее зафиксированный подтверждённый real-pool результат в рабочем журнале: 8.352 MH/s в среднем, диапазон 8.346–8.359 MH/s, A+23/R0. Он не заменяет защищённый baseline.

## Текущий этап

Основной активный путь — profiling-driven декомпозиция доминирующего matrix-row dataflow exact HotRun8 HooHash в ветке `agent/v21-v100-hotrun8-residual-profile`, PR #53, перед выбором нового speculative/filtered fast-path.

Exclusive V100 coarse residual census `33294578728` ранее дал: полный matrix-row budget 99.5862% sampled body cycles, `row_unclassified` 70.0919%, `outer_unclassified` 0.1435%. Следующий row coarse census `33296568418` завершён `PASS_DIAGNOSTIC` на 2 000 000 nonce и 452 samples: warm 8-cell batch path 20.6676%, прочая matrix-row работа 79.3324%. Диагностический throughput 5.949 MH/s не считается mining baseline.

В commit `2cc4cd1603195e8cd50b063dd304aa6482e75731` добавлен low-distortion sparse row-detail profiler. Он отдельно измеряет warm contribution preparation, warm commit (`sum` + exact `sw` update), scalar cold work, scalar warm-tail work и остаточный row budget. Exact arithmetic, state transitions, consensus, target и Stratum не изменяются; глобальные счётчики обновляются одним финальным flush на sampled nonce.

Hosted package/static gate `33298902358` завершён `PASS`: authoritative HooHash vector, 4 live consensus vectors и live nBits share-target boundaries совпали. Для `hoohash_mix_hotrun8_split_kernel` под `sm_70` получено 66 registers, 0 barriers, 112-byte stack frame и 0 spill stores/loads. Поэтому row-detail profiler допущен к exclusive V100 diagnostic run.

В commit `b150f26902bba9bbaa73cf38ded8406a82d975f8` добавлен immutable prerelease handoff `PepeW-Miner-v2.1 BETA HotRun8 Row Detail Profile`; hosted release workflow run `33301028003` выполняет повторный exact correctness/resource gate и публикацию SHA-проверяемого diagnostic asset без pool submission.

В приватном `PepePow_Lab` commit `1901f1b4dfd8e38c2803bc68a0236c6b90d701c5` добавил consumer `V100 HotRun8 Row Detail Profile`. Exclusive run `33301061447` сейчас `in_progress` под общей concurrency-группой `pepew-v100-exclusive`. Он ожидает immutable asset, проверяет SHA, использует постоянный cache по SHA, останавливает основной Hive miner только на время диагностического запуска и гарантированно восстанавливает его после завершения.

Новый speculative/LUT performance candidate пока сознательно не выбран: сначала нужен измеренный row-detail split. Blind warm-LUT, block-size, threads/min-blocks, synchronization и task-queue варианты не запускаются.

## Политика speculative/filtered кандидатов

Exact-кандидаты продолжают использовать прежние строгие проверки. Для speculative/filtered HooHash действует отдельная политика: relaxed offline target, измерение `strict_hits`, `fast_hits`, true positives, false negatives, false positives, recall и throughput. Любой fast hit перед pool submission обязан быть пересчитан exact strict GPU/CPU validator; недействительные кандидаты в пул не отправляются.

Начальный gate recall — не ниже 99.5%; приоритетный throughput gate до real-pool — не ниже +25%; invalid submissions после strict validation должны оставаться равны нулю. False positives допускаются только при дешёвой фильтрации, false negatives измеряются явно. Consensus и Stratum не меняются.

Standalone nonlinear LUT/FastSolver и standalone BLAKE3/orchestration ранее отсечены по закону Амдала. Следующий fast candidate выбирается только после row-detail census и отдельного nonlinear census аргументов/частот для доминирующего пути.

## Последний verdict

`ROW_DETAIL_HOSTED_STATIC_PASS / IMMUTABLE_HANDOFF_IN_PROGRESS / ROW_DETAIL_V100_CENSUS_IN_PROGRESS`.

Correctness regression не обнаружен. Защищённый baseline не изменён. Текущий этап диагностический и не является performance promotion.

## Действия пользователя

Не требуются.
