# Service4warp + guarded dual-LUT: production integration boundary

## Подтверждено

`sm_70` resource gate `32957864429` прошёл успешно. Worker probe: 30 registers, 0 spill stores/loads, 48 B stack, 22528 B shared. Guarded row probe: 46 registers, 0 spill stores/loads, 56 B stack, 25352 B shared.

## Почему интеграция должна оставаться внутри service4warp

Verified share-producing kernel использует `704` CUDA threads и `128` nonlinear service workers. `service_accumulate()` формирует shared queue, 128 workers вычисляют nonlinear contribution, после второго block barrier contribution возвращается owner-thread и только затем вызывается `update_sw_state(sw, sum)`. Это позволяет заменить exact `sincos/exp/sin` на fixed192 + dual-LUT именно внутри service workers, не меняя порядок зависимого HooHash state.

## Consensus-safe схема строки

1. На входе `matrix_row_service()` сохранить checkpoint `HooHashSwState sw_before_row`.
2. Для cold nonlinear task service worker вычисляет LUT approximation и строгий absolute error. `sqrt` остаётся exact; если fixed192 reducer не применим, выполняется exact nonlinear с error=0.
3. Owner-thread после каждого cell обновляет `sum` и `radius` и проверяет interval для следующего `sw`. Если `[sum-radius,sum+radius]` допускает разные значения cold/warm predicate, строка помечается ambiguous.
4. В конце строки дополнительно проверить, что `positive_double_to_u64_rz()` одинаков на границах interval.
5. При ambiguity откатить `sw=sw_before_row` и повторить только текущую 64-cell строку через существующий exact service path. При safe interval принять approximate row и продолжить HooHash.

## Ограничения

- Не переносить HooHash обратно в per-thread direct-row topology: production offline gate `32942402665` показал -81.201% при 0 mismatches.
- Не менять `threads/min_blocks/byte_unroll` в рамках этого кандидата.
- Не аппроксимировать `sqrt` на первом production варианте.
- Не отправлять candidate на real pool без >=100000 CPU↔CUDA Header80 cases, 0 mismatches, 0 spills и >=15% offline throughput gain.
- Финальная верификация только `accepted_delta > 0` с низкими rejects.

## Следующая реализация

Добавить guarded fields в `ColdServiceScratch`, production `service_accumulate_guarded()` и `matrix_row_service_guarded()` с exact row replay. После этого собрать полный `header80_pow_kernel`/candidate variant для `sm_70` и проверить ptxas до любого V100 hardware benchmark.
