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

## Почему нельзя просто поставить approximate exp

После HooHash выполняется финальный BLAKE3. Любая ошибка в mixed words полностью меняет итоговый hash. Поэтому схема «посчитать приблизительно, а exact проверить только найденные по approximate hash nonce» почти бесполезна: приблизительный final hash статистически не связан с consensus final hash.

Следовательно, безопасный быстрый путь обязан либо:

1. доказуемо выдавать те же HooHash mixed bytes, что exact path; либо
2. обнаруживать неоднозначность до финального BLAKE3 и выполнять exact fallback для конкретной cold-task/строки.

Это принципиальная граница для нашего Foztor-style fastpath.

## Новый кандидат: bounded nonlinear fastpath

Рабочая идея — не «неточный HooHash», а **приближение с гарантированной границей ошибки** и exact fallback.

Для exp-ветки аргумент `z = sin(y)+cos(y)` всегда находится в `[-sqrt(2), +sqrt(2)]`. Это маленький фиксированный диапазон, поэтому его можно покрыть компактной LUT или кусочно-полиномиальной аппроксимацией с известным абсолютным error bound.

Fastpath должен вести не только приближённую сумму `S`, но и консервативную погрешность `E`, так что exact sum гарантированно лежит в `[S-E, S+E]`.

### Guard 1: решение `sw`

После каждого cell consensus проверяет fractional state `frac(sum/1024) <= 0.02`. Approx path разрешён только если весь интервал `[S-E, S+E]` лежит по одну сторону ближайшей границы predicate. Если interval может пересечь границу `k*1024 + 20.48`, выполняется exact nonlinear для неоднозначной task и error interval сужается.

### Guard 2: итоговый byte пары строк

После двух строк используется только:

`(trunc(even_sum) + trunc(odd_sum)) & 0xff`.

Approx path считается доказанно consensus-safe, только если интервалы обеих сумм гарантируют те же целочисленные значения modulo 256. Если interval пересекает целочисленную границу, либо допускает другой low byte, соответствующая неоднозначная часть пересчитывается exact.

Таким образом, approximation никогда не должна попадать в финальный BLAKE3, если она может изменить consensus mixed byte.

## Почему это может дать крупный прирост

В отличие от `service4warp`, bounded fastpath уменьшает само число обращений к дорогим FP64 transcendental instructions. Если большая доля cold tasks находится далеко от `sw`/integer boundaries, LUT/polynomial path сможет обслуживать их без `sincos+exp` libdevice path. Exact FP64 останется только для малого ambiguous subset.

Это соответствует публичной истории Foztor: `exp-threshold` явно связывает скорость с контролируемым количеством incorrect/ambiguous computations, а v1.4.3 и v1.4.12 указывают на уменьшение FP64 работы и крупный выигрыш именно на DataCentre NVIDIA.

## Реализация по этапам

1. Добавить offline/reference измеритель распределения cold tasks: доля exp/sin/sqrt веток, расстояние от `sw`-границы и от integer/low-byte границ.
2. Построить `exp(z)` LUT/полином на `[-sqrt(2),sqrt(2)]` с формально заданным максимальным error bound.
3. Реализовать interval propagation для cold contribution `nonlinear(x) * value * 1234`.
4. Exact fallback при любом crossing `sw` boundary.
5. Exact fallback при неоднозначном final low byte пары строк.
6. CPU-vs-CUDA differential validation на большом наборе nonce; допустимо **0 mismatches**.
7. Проверка ptxas: registers, local memory, spills, shared memory.
8. Только после этого — один real-pool Tesla V100 test.
9. Продвижение только при `accepted_delta > 0`, низких Rejects и существенном приросте относительно 4.335 MH/s.

## Бинарный differential Foztor

Параллельно сохраняется приоритет анализа `sm_70` версий 1.4.8 → 1.4.12 → 1.4.14 → 1.4.17 → 1.4.23: kernel topology, FP64 instruction mix, transcendental calls, registers, shared/local memory, synchronization, LUT/precompute, batching и conditional paths. Ключевая цель — определить, какой именно класс expensive FP64 work исчезает или заменяется между версиями с крупными DataCentre gains.

## Что не делать

До завершения bounded-fastpath/differential не запускать новые серии `threads`, `min_blocks`, `byte_unroll` или последовательный перебор service-warps. Следующий hardware test должен проверять архитектурную гипотезу с потенциалом значительно больше нескольких процентов.
