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

Последний низкоискажающий V100 census показал: warm/scaled-table load 2.5320%, linear accumulation 1.4642%, `sw` 8.9602%, cold path 16.4606%, pair/final reduction 0.2848%, residual 70.2982%. Новый coarse profiler должен разделить residual на initialization/setup, matrix-row budget, pair-level outer work, row-unclassified и outer-unclassified.

Hosted packaging дважды был остановлен до V100 из-за дефектов диагностической обвязки, а не из-за производительности или корректности HooHash: сначала неверное имя profiling script, затем устаревший текстовый anchor после thread-local преобразования. Anchor исправлен в commit `91fd7730269bd403759329fd7a04bfb6b6c5ae9e`; exact arithmetic и consensus path не менялись.

Текущий hosted run: `33290158133`, состояние — выполняется. До его полного PASS, включая correctness и static resource gate со строгим отсутствием spills на `sm_70`, V100 diagnostic run не запускается.

## Политика кандидатов

Exact-кандидаты продолжают использовать прежние строгие проверки. Для speculative/filtered HooHash используется отдельная политика: relaxed offline target, измерение `strict_hits`, `fast_hits`, true positives, false negatives, false positives, recall и throughput. Любой fast hit перед pool submission обязан быть пересчитан exact strict GPU/CPU validator; недействительные кандидаты в пул не отправляются. Начальный gate recall — не ниже 99.5%, приоритетный throughput gate до real-pool — не ниже +25%, при обязательных нулевых invalid submissions после strict validation.

Standalone nonlinear LUT/FastSolver и standalone BLAKE3/orchestration ранее отсечены по закону Амдала. Новые LUT, block-size, synchronization и task-queue варианты без нового profiling evidence не создаются.

## Последний verdict

`HOSTED_DIAGNOSTIC_IN_PROGRESS` после исправления profiling anchor. Предыдущие два падения — `INFRASTRUCTURE/INSTRUMENTATION REJECT`, не performance reject.

## Действия пользователя

Не требуются.
