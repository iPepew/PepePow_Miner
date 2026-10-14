# Fail-closed admission для reduced-sincos кандидата — 2026-10-14

Экспериментальный `PEPEPOW_CUDA_INLINE_REDUCED_SINCOS` воспроизводит pinned libdevice polynomial именно для Tesla V100 / `sm_70`. До этой правки CMake позволял включить его без exact reducer или одновременно для других CUDA-архитектур.

Добавлен `native/cmake/ValidateReducedSincos.cmake` и его обязательное подключение из `native/CMakeLists.txt`. При включённом inline-кандидате конфигурация теперь допускается только если:

- `PEPEPOW_CUDA_DEMAND_SLICED_REDUCER=ON`;
- `PEPEPOW_CUDA_ARCHITECTURES=70-real` ровно, без PTX/JIT и смешанных архитектур.

Hosted run `38492143200` проверил шесть сценариев: два допустимых и четыре отрицательных. Итог 6/6 PASS. Отклоняются отсутствие reducer, generic `70`, смешанный `70-real;86-real` и `70-real;70-virtual`.

Первый run `38491878491` завершился ошибкой тестового сопоставления текста: CMake перенёс длинное диагностическое сообщение. Проверка исправлена до устойчивого короткого предиката; логика guard не менялась. Повтор прошёл. Workflow возвращён в ручной режим.

Коммиты:

- guard: `8cc7b1dadb07b0c2d87742dd44cdf5ed150d62cf`;
- подключение CMake: `e5a038e80cc3bc6e634789ce87a015745f772de5`;
- hosted-аудит: `925c11108fdcd8463b8fcc1d00c210fb62649098`.

CUDA-фрагмент остался byte-identical: blob `9c4590397ed3852c7343a62df03b738d59090eca`. GPU, пул и performance не запускались; это защита конфигурации, не подтверждение корректности на V100 или хешрейта.
