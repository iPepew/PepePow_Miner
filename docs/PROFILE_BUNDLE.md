# Сборка комплекта GPU-профилей

Это промежуточный комплект для интеграции, **не устанавливаемый HiveOS-пакет**.
Упаковщик не запускает бинарники и не выполняет GPU/пул проверки.

## Вход

Два каталога сборки: general и v100. В каждом требуются PROFILE_BUILD.json
и шесть файлов: pepepowminer, pepepow_core_tests, pepepow_cuda_tests,
pepepow_cuda_header80_validation, pepepow_header80_benchmark,
pepepow_header80_differential.

Manifest должен содержать source_commit (40 hex), status
compiled-cpu-tested-gpu-unverified и binary_sha256 со всеми шестью SHA256.
V100 helper build_v100_profile.py формирует такой результат.
Общий профиль должен формировать такой же manifest после настоящей сборки
и CPU-теста. Нельзя создавать его вручную, приписывая отсутствующие проверки.

Упаковщик проверяет заявленные SHA, но не является независимым доказательством
достоверности входного manifest. Надёжность происхождения обеспечивает
проверенный процесс сборки и сохранённые логи.

## Запуск

```sh
python3 scripts/release/package_profiles.py \
  --general /absolute/build-general \
  --v100 /absolute/build-v100 \
  --expected-general FULL_GENERAL_SOURCE_SHA \
  --expected-v100 91af54de51c7d83db6ce2074e71d9d37443d66bf \
  --version 1.0.0-preparation.1 \
  --output pepew-miner-1.0.0-preparation.1-profiles.tar.gz
```

FULL_GENERAL_SOURCE_SHA заменяется точным SHA фактической сборки.
Существующий выходной файл никогда не перезаписывается.
stdout содержит SHA256 итогового архива; сохраните его рядом с архивом.
Отдельный файл с хешем не включается внутрь самого архива.

## Выход и ограничения

Один корневой каталог pepew-miner. В bin/general и bin/v100 — майнеры;
в tests/offline/<profile> — соответствующие проверочные программы.
VERSION, README.md, BUILD_MANIFEST.json и SHA256SUMS формируются автоматически.
Список файлов фиксирован: wallet.conf, runtime state, логи и посторонние файлы
не копируются. Права нормализуются, время в tar/gzip равно нулю.
Хеши не доказывают отсутствие внешних библиотечных зависимостей.

Версия без суффикса -preparation.N запрещена. Manifest содержит installable=false.
Наличие профиля не означает корректность на GPU. В комплекте ещё нет HiveOS
адаптеров, выбранных runtime dependencies и финальных лицензионных материалов:
он не предназначен для публичного распространения как готовый майнер.

Присланный ранее архив 76972b56 не содержит matching offline executables и
PROFILE_BUILD.json нужного формата. Подставлять его как полноценный general build
нельзя: необходимо добавить упаковку проверочных программ в hosted build.

## Проверки

```sh
python3 tests/test_package_profiles.py
```

7 локальных проверок: воспроизводимость архива, состав/права/хеши/исключение
секретов, повреждённый бинарник, отсутствие differential, symlink, неверный source,
попытка обозначить preparation как stable. Данные тестов синтетические;
настоящая CUDA compilation и исполнение GPU не выполняются.
