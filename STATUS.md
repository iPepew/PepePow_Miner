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

Основной активный путь — диагностическая декомпозиция остаточного бюджета циклов внутри exact HotRun8 HooHash body в ветке `agent/v21-v100-hotrun8-residual-profile`, PR #53.

Последний низкоискажающий V100 census показал: warm/scaled-table load 2.5320%, linear accumulation 1.4642%, `sw` 8.9602%, cold path 16.4606%, pair/final reduction 0.2848%, residual 70.2982%. Новый coarse profiler разделяет residual на initialization/setup, matrix-row budget, pair-level outer work, row-unclassified и outer-unclassified.

Hosted package run `33290158133` завершён успешно. Exact consensus vectors прошли проверку; сборка `sm_70` для `hoohash_mix_hotrun8_split_kernel` использует 70 регистров, 0 barriers, 112 байт stack frame и 0 spill stores/loads. Значит диагностический кандидат прошёл correctness и static resource gate.

Первый immutable release handoff run `33291942596` завершился инфраструктурной ошибкой на шаге публикации: в CUDA container отсутствовала команда `gh`, поэтому prerelease asset не был создан. Следующий Lab run `33291970147` вследствие этого не запускал benchmark binary и завершился после повторяющихся HTTP 404 при ожидании SHA asset. Это не performance REJECT и не correctness REJECT; V100 вычислительный тест фактически не состоялся.

Причина исправлена в release workflow: установлен GitHub CLI `gh`, добавлены явные проверки `command -v gh` и `gh --version` до сборки/публикации. Текущий head исправления — `093c8142f24bf15b6cd68f3233245f0a239f225d`; push этого workflow запускает новый hosted release handoff. После появления immutable asset следующий V100 residual census должен выполняться только через `pepew-v100-exclusive` и использовать SHA-кэш на self-hosted runner.

## Политика кандидатов

Exact-кандидаты продолжают использовать прежние строгие проверки. Для speculative/filtered HooHash используется отдельная политика: relaxed offline target, измерение `strict_hits`, `fast_hits`, true positives, false negatives, false positives, recall и throughput. Любой fast hit перед pool submission обязан быть пересчитан exact strict GPU/CPU validator; недействительные кандидаты в пул не отправляются. Начальный gate recall — не ниже 99.5%, приоритетный throughput gate до real-pool — не ниже +25%, при обязательных нулевых invalid submissions после strict validation.

Standalone nonlinear LUT/FastSolver и standalone BLAKE3/orchestration ранее отсечены по закону Амдала. Новые LUT, block-size, synchronization и task-queue варианты без нового profiling evidence не создаются. Следующий speculative fast-path выбирается только после измеренного coarse residual split.

## Последний verdict

`HOSTED_STATIC_PASS / RELEASE_HANDOFF_INFRA_REJECT / FIX_PUSHED`.

Последняя ошибка относится только к инфраструктуре передачи immutable диагностического пакета. Performance verdict нового fast-кандидата ещё не выставлялся, correctness regression не обнаружен, защищённый baseline не изменён.

## Действия пользователя

Не требуются.
