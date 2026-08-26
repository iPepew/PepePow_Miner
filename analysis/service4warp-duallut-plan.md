# Service4warp + dual-LUT architecture candidate

## Причина перехода

Production Header80 offline gate для `guarded-duallut-rowcp` прошёл correctness: 100000 CPU↔CUDA cases, 0 mismatches, 0 spills. Но throughput составил 0.666 MH/s против 3.542 MH/s exact Header80 backend (-81.201%). Поэтому row-checkpoint/direct guarded topology отклоняется как performance architecture.

## Что сохраняем

Сохраняем доказанные и полезные части guarded-LUT работы:

- fixed192 phase reducer;
- main LUT ~768 KiB для `exp(sin+cos)`;
- secondary LUT ~128 KiB для `sin²`;
- error bounds / exact fallback semantics;
- host-side LUT generation/upload;
- production Header80 differential harness.

## Что меняем

Не заменяем verified `service4warp` topology. Новый кандидат должен начинаться от `agent/v21-v100-service4warp` и оставить:

- block geometry 704 threads;
- 128 nonlinear service workers;
- текущую shared task queue;
- текущий share-producing Header80/BLAKE3/Stratum semantics.

LUT fastpath переносится внутрь service workers как замена дорогих cold nonlinear `sincos/exp/sin` вычислений, а не как отдельный per-thread HooHash solver.

## Главная гипотеза

`service4warp` уже доказал +5.7% real-pool improvement и 4.335 MH/s A+109/R0. Guarded LUT доказал exactness на 100000 cases, но проиграл из-за topology. Комбинация должна сохранить throughput scheduler-а `service4warp` и снизить FP64 transcendental work на cold tasks.

## Gates

До real-pool V100 test кандидат обязан пройти:

1. native sm_70 compile;
2. 0 spill loads/stores;
3. >=100000 production Header80 CPU↔CUDA differential cases;
4. 0 mismatches;
5. offline throughput >= +15% относительно exact service4warp-equivalent backend.

Продвижение только после real-pool `accepted_delta > 0` и низких rejects. Live `hiveos-v100-kernel-v2-test` не менять до verified share-producing improvement.
