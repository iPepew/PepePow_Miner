# Архитектурный анализ V100: PepeW против Foztor

## Цель

Найти изменения уровня solver, способные дать кратный прирост HooHash на Tesla V100. Микротюнинг `threads`, `min_blocks`, `byte_unroll` и механический перебор числа service-warps больше не рассматриваются как основной путь.

## Подтверждённая рабочая база PepeW

Текущий лучший real-pool результат: `service4warp`, **4.335 MH/s, Accepted +109, Rejected +0**, диапазон 4.317–4.345 MH/s. Расширение nonlinear service pool с 32 до 128 потоков дало около +5.7% к прежним 4.101 MH/s. Это подтверждает, что cold nonlinear FP64/transcendental stage является реальным bottleneck, но одно лишь расширение worker pool не объясняет разрыв до Foztor (~26 MH/s).

## Что уже оптимизировано в PepeW

Предыдущая гипотеза о 4096 обычных `floor()` на nonce устарела. Production-путь уже использует битовые/exact fast paths для `sw` и selector decoding. В частности:

- `sw` хранится как predicate и обновляется через `positive_fraction_div1024_le_002_finite()`;
- `one_region` извлекается из IEEE-754 битов;
- `two = frac(2*one_base)` восстанавливается без второго общего `floor()`;
- `safe_nonlinear()` для валидного диапазона не выполняет retry loop.

Поэтому дальнейшая оптимизация должна быть сосредоточена на самой дорогой nonlinear математике, а не на уже устранённом bookkeeping overhead.

## Текущий дорогой nonlinear path

Для cold-cell PepeW вычисляет:

1. `one_base = x * 1e-6 / 8`;
2. selector и transform `y`;
3. одну из трёх веток:
   - `exp(sin(y) + cos(y))` через `sincos + exp`;
   - `sin(y)^2`;
   - `1 / sqrt(abs(y) + 1)`.

`service4warp` лишь выполняет эти операции шире; число transcendental/FP64 операций на cold task не уменьшается.

## Подтверждённые публичные сигналы Foztor

История hoo_gpu даёт последовательные архитектурные подсказки:

- v1.1.28: появился `--exp-threshold` (0.1–2.0). Более высокий threshold повышает hashrate, но увеличивает incorrect calculations; более низкий уменьшает ошибки ценой скорости.
- v1.1.29: переход на per-architecture fatbins, что прямо открывает путь для отдельных оптимизаций `sm_70`.
- v1.4.3: разработчик сообщает о **reduced FP64 calculations** и приросте HooHash.
- v1.4.12: заявлено **+40–80% HooHash на Nvidia DataCentre GPU**, тогда как gaming NVIDIA получает до ~5%. Это особенно важно для V100.
- v1.4.14: дополнительный прирост на части DataCentre GPU и Titan V.
- v1.4.17: фактический hashrate вырос на всех NVIDIA GPU; solver стал сильнее зависеть от core clock, память рекомендуется держать низко.

Совокупность этих изменений указывает на уменьшение количества/стоимости FP64 transcendental work на nonce и архитектурно специализированный solver, а не только launch tuning.

## Новый измеренный факт: high/sqrt ветка почти всегда микроскопическая

Добавлен детерминированный reference-probe `analysis/hoohash_high_branch_probe.py` в ветке `agent/v21-v100-high-branch-probe`. Hosted run `32859090996` успешно обработал 512 synthetic/reference nonce-проходов.

Результаты:

- в среднем **125.46 cold nonlinear tasks на nonce**;
- распределение веток: `exp` 32.88%, `sin²` 32.52%, `1/sqrt` **34.61%**;
- следовательно, около **43.4 sqrt-тасков на nonce** в среднем;
- 100% high/sqrt задач имели `|y| >= 2^30`;
- **99.72%** имели `|y| >= 2^40`;
- **97.27%** high-вкладов были меньше `0.001`;
- **99.87%** high-вкладов были меньше `0.01`;
- грубое зануление всей high-ветки изменило итоговые mixed bytes только в **10 из 512** проходов (**1.95%**).

Последний пункт не разрешает занулять ветку в production, но показывает, что почти вся цена FP64 `sqrt` платится за вклад, который обычно не влияет на consensus byte. Это намного сильнее обосновывает guarded-elision, чем общий approximate-exp как первый эксперимент.

## Новый приоритет: guarded high-branch elision

Следующий architecture-level fastpath должен сначала атаковать `1 / sqrt(abs(y)+1)`, потому что здесь можно избежать дорогой операции, используя только дешёвую классификацию масштаба `|y|` и консервативную верхнюю границу вклада.

Идея:

1. Для high-ветки не считать `sqrt` сразу.
2. По exponent/`|y|` получить верхнюю границу `delta_max` для вклада `value*1234/sqrt(|y|+1)` без transcendental math.
3. Вести интервал суммы `[S, S+E]`, где `E` — накопленная максимальная величина пропущенных положительных high-вкладов.
4. После каждого cell продолжать speculative path только если весь interval даёт один и тот же `sw` predicate.
5. На границе строки/пары принимать fastpath только если interval гарантирует тот же `trunc(sum)`/low byte.
6. При неоднозначности выполнять exact fallback для строки/пары, а не выпускать approximate state в финальный BLAKE3.

Поскольку high-вклад всегда положителен, interval здесь односторонний и проще, чем для общего exp/sin approximation. Если измеренная доля fallback останется около нескольких процентов, можно убрать почти треть cold transcendental вызовов, сохранив 0 consensus mismatches.

## Почему нельзя просто поставить approximate exp

После HooHash выполняется финальный BLAKE3. Любая ошибка в mixed words полностью меняет итоговый hash. Поэтому схема «посчитать приблизительно, а exact проверить только найденные по approximate hash nonce» почти бесполезна: приблизительный final hash статистически не связан с consensus final hash.

Следовательно, безопасный быстрый путь обязан либо:

1. доказуемо выдавать те же HooHash mixed bytes, что exact path; либо
2. обнаруживать неоднозначность до финального BLAKE3 и выполнять exact fallback для конкретной строки/пары.

## Второй приоритет: bounded exp fastpath

После guarded high-elision остаётся bounded fastpath для `exp(sin(y)+cos(y))`. Аргумент `z = sin(y)+cos(y)` всегда лежит в `[-sqrt(2), +sqrt(2)]`, поэтому можно использовать LUT/кусочно-полиномиальную аппроксимацию с формальным error bound и тем же interval/fallback механизмом.

## Реализация по этапам

1. Реализовать guarded high/sqrt elision на основе exponent-bound и row/pair exact fallback.
2. CPU-vs-CUDA differential validation: допустимо **0 mismatches**.
3. Измерить фактическую fallback rate и число реально устранённых `sqrt` вызовов.
4. Проверить ptxas/registers/spills/shared memory.
5. Только если fastpath действительно устраняет значимую долю sqrt — один real-pool V100 test.
6. После этого переходить к bounded `exp` LUT/polynomial.
7. Продвижение только при `accepted_delta > 0`, низких Rejects и существенном приросте относительно 4.335 MH/s.

## Бинарный differential Foztor

Параллельно сохраняется приоритет анализа `sm_70` версий 1.4.8 → 1.4.12 → 1.4.14 → 1.4.17 → 1.4.23: kernel topology, FP64 instruction mix, transcendental calls, registers, shared/local memory, synchronization, LUT/precompute, batching и conditional paths. Ключевая цель — определить, какой именно класс expensive FP64 work исчезает или заменяется между версиями с крупными DataCentre gains.

## Что не делать

До завершения guarded-fastpath/differential не запускать новые серии `threads`, `min_blocks`, `byte_unroll` или последовательный перебор service-warps. Следующий hardware test должен проверять архитектурную гипотезу с потенциалом значительно больше нескольких процентов.
