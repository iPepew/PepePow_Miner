# Полный CPU-аудит reduced-sincos пути — 2026-10-13

Кандидат закреплён на source commit `d07c0f27507295ee0539641d8bb656ba70116bd4`, blob `native/src/cuda/v1/header80_backend_part03.inc` — `9c4590397ed3852c7343a62df03b738d59090eca`. PTX fixture SHA-256: `483af6855a12c1927895b547f4e43b2893d52271fbcd3c621c1fdbe989fb7971`.

Новый воспроизводимый аудит компилирует фактический полный путь `exact_fixed_window_reduce -> exact_reduced_sincos_polynomial -> quadrant mapping` через явные CPU-шлюзы CUDA intrinsic. Для каждой степени 31–56 проверены граничные мантиссы и детерминированные случайные значения: всего 3432 входа.

Результат:

- g++ 13.3.0, `-O0`: 3432/3432, 0 bitwise mismatches;
- g++ 13.3.0, `-O2`: 3432/3432, 0 bitwise mismatches;
- независимый Decimal-оракул с точностью 110 знаков: 0 ошибок квадранта, 0 выходов остатка за ±π/4;
- максимальная абсолютная ошибка редуцированного остатка: `5.5508327120374628627e-17`, лимит `2^-53`;
- обнаружены все четыре отрицательные мутации: константа reducer, сдвиг round-bit, перестановка выхода квадранта и верхняя граница exponent gate.

Скрипт: `PepePow_Lab/scripts/ci/audit_reduced_sincos_full_host.py`.
Отчёт: `PepePow_Lab/results/analysis/reduced-sincos-full-host-20261013.json`.

Это CPU-only доказательство связности полного пути. CUDA/V100 не выполнялась, GPU admission остаётся false, скорость и прирост не измерялись. Production, stable/live, пул и release не менялись. Следующий обязательный gate после возвращения V100 — exact-package CUDA correctness и только затем сопоставимый offline ABBA.
