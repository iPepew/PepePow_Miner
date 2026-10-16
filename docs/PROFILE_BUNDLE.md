# Упаковка профилей PepeW Miner

Пакет остаётся preparation: GPU/pool-приёмка не выполнена. Упаковщик не
запускает бинарники. Без --runtime создаётся комплект из двух профилей;
с --runtime добавляются проверенные CPU-тестами адаптеры HiveOS и документы.
Это не объявление готового стабильного выпуска.

## Проверенные входы

Для 1.0.0-preparation.2 используются результаты Actions run 38906725960:
- general source 33ca7ff88acffb93dc36835d8fa99177b094d7c0;
- v100 source 91af54de51c7d83db6ce2074e71d9d37443d66bf;
- runtime source 8e08a9f8c77c3fa7587c8507845d9c473e0b0a0d.

В каждом build-каталоге нужны PROFILE_BUILD.json и шесть файлов:
pepepowminer, pepepow_core_tests, pepepow_cuda_tests,
pepepow_cuda_header80_validation, pepepow_header80_benchmark,
pepepow_header80_differential. Manifest содержит source_commit, status
compiled-cpu-tested-gpu-unverified и binary_sha256 всех шести файлов.
Происхождение manifest подтверждается журналами сборки, а не одним полем status.

```sh
python3 scripts/release/package_profiles.py \\
  --general /absolute/build-general \\
  --v100 /absolute/build-v100 \\
  --expected-general 33ca7ff88acffb93dc36835d8fa99177b094d7c0 \\
  --expected-v100 91af54de51c7d83db6ce2074e71d9d37443d66bf \\
  --runtime /absolute/runtime-checkout \\
  --runtime-commit 8e08a9f8c77c3fa7587c8507845d9c473e0b0a0d \\
  --version 1.0.0-preparation.2 \\
  --output pepew-miner-1.0.0-preparation.2-linux-x86_64-hiveos.tar.gz
```

Runtime-каталог должен соответствовать указанному SHA; упаковщик записывает
заявленный SHA и точные хеши файлов, но не обращается к GitHub для его проверки.
В проведённой сборке соответствие файлов Git blob SHA проверено отдельно.
Существующий выходной файл не перезаписывается; stdout содержит SHA256 архива.

## Выход

Один каталог pepew-miner: бинарники в bin/{general,v100}, matching tests в
 tests/offline/{general,v100}. При --runtime добавляются root launcher,
h-manifest.conf, h-config.sh, h-run.sh, h-stats.sh, libexec, README, CHANGELOG,
LICENSE и notices. Полный вариант содержит 28 файлов. BUILD_MANIFEST.json
сохраняет source/hashes, SHA256SUMS охватывает остальные 27 файлов.

Состав задаётся allowlist; wallet.conf, runtime state, логи и лишние файлы не
копируются. Symlink запрещены. Права фиксированы, tar/gzip timestamps нулевые.
Версия без -preparation.N запрещена; installable=false сохраняется до приёмки.
PEPEW_ALLOW_UNVERIFIED=1 — технический переключатель согласованного испытания,
не разрешение на GPU/pool. Текущий V100-риг не опрашивать до возвращения карты.

## Результат и оставшиеся gates

Фактический архив, его SHA256 и результаты записаны в
[результате](../results/release/public-1.0-preparation.2.json).
12 бинарников сохранены побайтно из исходного артефакта; заново не компилировались.
9 тестов упаковщика, 10 runtime-тестов с имитаторами, 6 config и 2 pool-parser
проверки прошли. /proc/exe identity в runtime-тесте подставлен: этот хост запрещает
его чтение; реальная проверка на HiveOS остаётся обязательной.

До stable: exact GPU correctness, разрешённый pool gate, целевая HiveOS,
GLIBC_2.34/GLIBCXX_3.4.30 и CUDA redistribution inventory. Проверки CPU и наличие
лицензионных файлов не доказывают завершение этих gates.

