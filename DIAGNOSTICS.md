# PepePow Miner diagnostic bundle

The diagnostic build writes deterministic runtime evidence to the miner log. It records build identity, Stratum difficulty, calculated target, job fields, header80, hashes, submit payload fields, accepted/rejected counters and CPU/CUDA validation results.

Use `--diagnostic` to enable verbose job and share tracing. Use `--diagnostic-file PATH` to duplicate diagnostic records to a dedicated file.
