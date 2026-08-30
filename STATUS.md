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

Exclusive V100 coarse residual census `33294578728` ранее дал: полный matrix-row budget 99.5862% sampled body cycles, `row_unclassified` 70.0919%, `outer_unclassified` 0.1435%. Это исключило внешний pair/orchestration path как самостоятельную цель и локализовало основной резерв внутри строки матрицы.

Следующий exclusive V100 row coarse census `33296568418` завершён `PASS_DIAGNOSTIC` на 2 000 000 nonce и 452 sparse samples. Диагностический throughput составил 5.949 MH/s и не считается mining baseline. Измерено: полный sampled row/body budget 6 058 764 464 cycles; warm 8-cell batch segments 1 252 202 365 cycles = 20.6676%; прочая matrix-row работа 4 806 562 099 cycles = 79.3324%. Зафиксировано 237 718 warm groups, в среднем 525.925 группы на sampled nonce.

Это важный архитектурный отсев: даже идеальное устранение всей стоимости warm-batch path имеет теоретический Amdahl-потолок около +26.1% относительно измеренного row budget и на практике оставляет слишком малый запас над требуемым pre-pool gate +25%. Поэтому новый кандидат не строится как очередная blind warm-LUT/precompute замена. Основной дальнейший поиск направлен на 79.33% `other` внутри matrix-row.

В commit `2cc4cd1603195e8cd50b063dd304aa6482e75731` добавлен новый low-distortion sparse row-detail profiler. Он независимо измеряет: warm contribution preparation, warm commit (`sum` + exact `sw` update), scalar cold work, scalar warm-tail work и остаточный row budget. Exact arithmetic, state transitions, consensus, target и Stratum не изменяются; глобальные счётчики сбрасываются один раз на запуск и обновляются только одним финальным flush на sampled nonce.

В commit `342fd137562628903026c406d3ed59b4c34364fb` добавлен hosted package/static gate для row-detail profiler. Workflow run `33298902358` запущен и сейчас выполняется. До допуска на V100 обязательны: authoritative/core correctness PASS, `sm_70`, отсутствие CUDA spills и проверка resource footprint. V100 одновременно не запускается; следующий hardware diagnostic будет только через общую exclusive-группу `pepew-v100-exclusive` после hosted PASS.

## Политика speculative/filtered кандидатов

Exact-кандидаты продолжают использовать прежние строгие проверки. Для speculative/filtered HooHash действует отдельная политика: relaxed offline target, измерение `strict_hits`, `fast_hits`, true positives, false negatives, false positives, recall и throughput. Любой fast hit перед pool submission обязан быть пересчитан exact strict GPU/CPU validator; недействительные кандидаты в пул не отправляются.

Начальный gate recall — не ниже 99.5%; приоритетный throughput gate до real-pool — не ниже +25%; invalid submissions после strict validation должны оставаться равны нулю. False positives допускаются только при дешёвой фильтрации, false negatives измеряются явно. Consensus и Stratum не меняются.

Standalone nonlinear LUT/FastSolver и standalone BLAKE3/orchestration ранее отсечены по закону Амдала. Новые block-size, threads/min-blocks, synchronization, task-queue и blind single-function LUT варианты без нового profiling evidence не создаются.

## Последний verdict

`ROW_COARSE_V100_PASS_DIAGNOSTIC / ROW_DETAIL_HOSTED_IN_PROGRESS`.

Correctness regression не обнаружен. Защищённый baseline не изменён. Row coarse result является диагностическим PASS, а не performance promotion.

## Действия пользователя

Не требуются.
