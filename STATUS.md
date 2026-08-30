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

Основной активный путь — профилирование доминирующей работы внутри строки матрицы exact HotRun8 HooHash в ветке `agent/v21-v100-hotrun8-residual-profile`, PR #53.

Exclusive V100 coarse residual census `33294578728` завершён успешно на 2 000 000 nonce и 452 sparse samples. Диагностический хешрейт составил 4.616 MH/s и не считается mining baseline. Измерено: warm/scaled-table load 2.5628%, linear accumulation 1.3337%, `sw` 9.1945%, cold path 16.4033%, pair/final reduction 0.2703%, residual 70.2355%. Полный matrix-row budget занимает 99.5862% sampled body cycles. Главное новое измерение: `row_unclassified` занимает 70.0919% всего sampled budget, тогда как `outer_unclassified` только 0.1435%. Cold-cell fraction — 7.1348%.

Следовательно, внешний pair/orchestration path практически исключён как самостоятельная цель. Основной неисследованный резерв находится внутри matrix-row dataflow; именно он имеет достаточный теоретический Amdahl-потолок, чтобы оправдать дальнейший speculative/filtered поиск.

Для следующего слоя создан low-overhead row coarse profiler. Hosted package run `33294695657` завершён успешно: authoritative HooHash vector и 4 live consensus vectors совпали, share-target boundaries совпали; `sm_70` `hoohash_mix_hotrun8_split_kernel` использует 50 регистров, 0 barriers, 112 байт stack frame и 0 spill stores/loads. Пакет SHA-256: `619d03fec3e47591003c8f0db76bb6a8e67f6ec40600c40945e73716b20e3d67`.

Добавлен immutable release handoff для row profiler, commit `cf7904731be0900ca9f5906091923260017078e0`; hosted release run `33296553168` выполняется. В приватном Lab добавлен отдельный consumer commit `87679e3ca1919e8f118225211ee700c535dc8fb7`; exclusive V100 run `33296568418` уже выполняется под общей concurrency-группой `pepew-v100-exclusive` и ожидает exact SHA asset при необходимости. Runner использует постоянный cache по SHA и не должен повторно скачивать/распаковывать неизменный пакет.

Row coarse profiler измеряет полную стоимость warm 8-cell batch относительно общего HooHash body без per-cell timers. Это следующий диагностический шаг перед более детальной декомпозицией matrix-row и перед выбором первого нового speculative/filtered кандидата. Consensus arithmetic и Stratum path не изменены, pool submission в profiler отсутствует.

## Политика кандидатов

Exact-кандидаты продолжают использовать прежние строгие проверки. Для speculative/filtered HooHash используется отдельная политика: relaxed offline target, измерение `strict_hits`, `fast_hits`, true positives, false negatives, false positives, recall и throughput. Любой fast hit перед pool submission обязан быть пересчитан exact strict GPU/CPU validator; недействительные кандидаты в пул не отправляются. Начальный gate recall — не ниже 99.5%, приоритетный throughput gate до real-pool — не ниже +25%, при обязательных нулевых invalid submissions после strict validation.

Standalone nonlinear LUT/FastSolver и standalone BLAKE3/orchestration ранее отсечены по закону Амдала. Новые block-size, threads/min-blocks, synchronization, task-queue и blind single-function LUT варианты без нового profiling evidence не создаются. Следующий fast-path будет выбран по измеренному matrix-row split.

## Последний verdict

`RESIDUAL_CENSUS_PASS / ROW_HOSTED_STATIC_PASS / ROW_V100_CENSUS_IN_PROGRESS`.

Correctness regression не обнаружен. Защищённый baseline не изменён. Последний завершённый аппаратный результат является диагностическим PASS, а не performance promotion.

## Действия пользователя

Не требуются.
