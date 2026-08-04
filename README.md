# PepeW Miner

CUDA-майнер PEPEPOW HooHash V110 с интеграцией HiveOS.

## Stable HiveOS package

```text
PepeW Miner v1.0.2
```

Версия `v1.0.2` — HiveOS-обновление поверх проверенного CUDA-ядра `service768`.
Вычислительная часть и производительность RTX 3080 сохранены; исправлены установка
пакета и отображение статистики по каждой видеокарте.

## Что исправлено в v1.0.2

- общий хешрейт передаётся через shell-переменную `khs`;
- хешрейт каждой видеокарты передаётся через массив `hs[]` в kH/s;
- `hs[]`, `temp[]`, `fan[]` и `bus_numbers[]` синхронизированы по индексу GPU;
- PCI bus, например `02:00.0`, связывает телеметрию с правильной строкой видеокарты;
- поддерживаются несколько GPU через `GPU0_HPS`, `GPU1_HPS` и последующие поля;
- архив содержит верхний каталог `PepeW-Miner-v1.0.2-HiveOS/`, который совпадает
  с Miner name в полётном листе и путём установки HiveOS;
- сохранены Accepted/Rejected, uptime, температура и вентилятор.

## Поддерживаемая платформа

```text
Linux x86_64
HiveOS
NVIDIA Ampere sm_86
RTX 30 series
```

## HiveOS

Miner name:

```text
PepeW-Miner-v1.0.2-HiveOS
```

Pool URL:

```text
stratum+tcp://stratum-eu.pepepow.foztor.net:13232
```

Wallet template:

```text
%WAL%.%WORKER_NAME%
```

Password:

```text
x
```

Дополнительные аргументы не требуются.

## Проверенная производительность RTX 3080

```text
release benchmark median: 2.208874 MH/s
CTest:                   PASS
CPU/CUDA consensus:      PASS
Compute Sanitizer:       PASS
CUDA spills:             0 / 0
new NVIDIA Xid:          0
```

Подробности: [`RELEASE_NOTES_v1.0.2.md`](RELEASE_NOTES_v1.0.2.md).

## Safety

Запускайте майнинг только на оборудовании, которым вы владеете или имеете право
пользоваться. Контролируйте температуру, питание и стабильность системы.

## License

MIT License. See [`LICENSE`](LICENSE).
