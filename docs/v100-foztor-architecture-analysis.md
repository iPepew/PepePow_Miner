# Архитектурный анализ V100: PepeW против Foztor

## Цель

Цель — найти solver-level изменение, способное дать кратный прирост HooHash на Tesla V100. Микротюнинг `threads`, `min_blocks` и `byte_unroll` больше не считается основным путём: подтверждённые real-pool тесты изменяют скорость лишь на единицы процентов вокруг 4.1 MH/s.

## Подтверждённая база PepeW

Лучший real-pool результат: `threads=704`, `min_blocks=1`, **4.101 MH/s, Accepted +68, Rejected +0**. `byte_unroll=2` дал 4.085 MH/s, A+115/R+1 и отклонён.

## Коррекция гипотезы `sw/floor`

Первоначально подозревался 4096-кратный FP64 `floor()` при обновлении `sw`. Для фактически собираемого v2.1 это уже не главный bottleneck: production использует `PEPEPOW_CUDA_SW_STATE_MODE=3`, где fractional-state проверяется exact bitwise predicate вместо общего `floor()` path. Поэтому отдельный `sw-fastpath` отменён.

## Главный выявленный bottleneck: block-wide cold-service serialization

Share-producing `header80_pow_kernel` использует `hoohash_mix_words_service()`. Для каждого matrix cell функция `service_accumulate()` делает следующее:

1. Определяет cold nonlinear-задачи внутри каждого warp через ballot.
2. Резервирует слоты общей shared-очереди через `atomicAdd()`.
3. Записывает `task_x`, `task_value`, `task_owner` в shared memory.
4. Выполняет первый `__syncthreads()`.
5. Все nonlinear-задачи блока выполняет только первый warp (`threadIdx.x < 32`).
6. Выполняет второй `__syncthreads()`.
7. Только после этого остальные warp продолжают свой nonce.

На один HooHash приходится 64 строки × 64 cells = **4096 вызовов `service_accumulate()`**. Следовательно, блок проходит до **8192 block-wide barriers** за один HooHash плюс тысячи ballot/atomic/shared-memory операций.

При `threads=704` блок содержит 22 warp. Все они обязаны останавливаться на каждом matrix cell, даже если конкретный warp не имеет cold nonlinear-задачи. При этом дорогую nonlinear FP64 работу обслуживает только первый warp. Это создаёт две формы потерь одновременно:

- глобальная синхронизация 22 warp с частотой до 8192 barriers/HooHash;
- принудительная сериализация cold FP64 задач через один warp вместо независимой работы warp/thread.

Это архитектурная проблема с потенциально кратным эффектом и намного более сильная гипотеза, чем изменение launch geometry.

## Почему direct path — правильный первый эксперимент

В коде уже существует `hoohash_mix_words()`, где каждый CUDA thread независимо выполняет тот же HooHash без shared task queue, `atomicAdd()` и per-cell `__syncthreads()`. Этот путь используется split-pipeline кодом и реализует те же consensus-операции.

Кандидат `nobarrier-direct` меняет только планирование вычислений:

- HooHash/Stratum semantics сохраняются;
- `threads=704`, `min_blocks=1`, `SW_STATE_MODE=3`, scaled matrix/nibble table и native `sm_70` сохраняются;
- shared `ColdServiceScratch` перестаёт использоваться в основном fused kernel;
- каждый nonce выполняет `hoohash_mix_words()` независимо.

Эксперимент специально не совмещает это изменение с другими оптимизациями, чтобы измерить вклад именно block-wide service serialization.

## Связь с Foztor

Foztor сообщал о крупных ускорениях после сокращения FP64 work и отдельных оптимизаций DataCentre GPU. Из предоставленных Foztor-архивов также видны специализированные `sm_70` образы, LUT для `exp()` и собственный autotuning. Это указывает на solver, рассчитанный на эффективную загрузку Volta, а не на глобальную синхронизацию большого CUDA-блока вокруг редких transcendental задач.

Текущий differential вывод: PepeW может проигрывать Foztor не только из-за числа FP64 инструкций, но и из-за того, **как** эти операции планируются. Даже редкая nonlinear-ветка становится дорогой, если каждый её возможный вызов заставляет синхронизироваться весь блок.

## Текущий архитектурный кандидат

Рабочее имя: `v21-v100-nobarrier-direct`.

Hosted workflow упрощён после первого zero-job failure. Новый commit workflow: `7c0928f6d90c05d19512b84f6639905e13dd19f6`.

Перед hardware promotion обязательны:

1. успешная native `sm_70` сборка;
2. отсутствие недопустимых ptxas spills;
3. прохождение имеющихся correctness tests;
4. isolated package только после build gate;
5. ровно один real-pool V100 test;
6. `accepted_delta > 0`, низкие Rejects и заметный прирост относительно 4.101 MH/s.

Номинальный kernel MH/s без Accepted shares не считается успехом.

## Если direct path даст крупный прирост

Следующий шаг будет не новый перебор geometry, а дальнейшее уменьшение стоимости nonlinear path по мотивам Foztor: LUT/precompute для `exp()` и сокращение независимых FP64/transcendental вычислений с differential correctness gate.

## Если direct path не даст крупного прироста

Тогда bottleneck переносится внутрь самого per-thread HooHash. Следующие измерения: instruction/resource profile `hoohash_mix_words`, доля FP64/transcendentals, register pressure/local memory и возможность вынести invariant terms или использовать guarded LUT/precompute. Перебирать `threads/min_blocks/byte_unroll` снова не планируется.

## Что не делать

До завершения архитектурного differential loop не запускать новые варианты, ожидаемый эффект которых составляет несколько процентов. Каждый аппаратный тест должен проверять отдельную гипотезу с потенциально крупным эффектом.
