# Guard shared HiveOS evidence arguments

Reviewed source: `70ca18e1f95d8269168b9075ea301e66074181c9`.

`hiveos/h-run.sh` starts one miner per selected GPU, from the same working
directory, and passes the same `PEPEPOW_EXTRA_ARGS` to every process.
`EvidenceFile` opens the requested path with `O_CREAT | O_EXCL`. Consequently
passing `--stratum-evidence PATH` through the shared HiveOS expert field gives
every worker the same destination: later opens fail. This is a source-level
integration finding, not a measured hardware failure.

The old configuration generator accepted the unsafe argument (reproduced with
synthetic settings in a temporary directory). The generator now rejects it
before writing config.txt or setup.txt. An existing configuration is preserved.
Both separated and equals forms are reserved. The direct console option is
unchanged and still requires a unique file for each process/run. No wrapper
support for per-GPU evidence files is claimed. Hand-edited config.txt files
bypass the generator and must not contain this shared option.

Validation: `bash -n hiveos/h-config.sh` and ten local Python unittest cases.
The tests run only the real configuration generator in isolated temporary
directories with synthetic values and a three-second subprocess timeout.
They cover absolute/relative/quoted/empty paths, equals form, option order,
preservation of an existing configuration, default/diagnostic behavior, and
the existing reserved diagnostic-log option. No miner/proxy/GPU is started.

```sh
python3 -m unittest discover -s tests -p 'test_hiveos_evidence_config.py' -v
```

Packaging review also found the existing exact-reducer workflow pinned to
`9879165760a736a62969b373e6673112e4d04a1b`, with a 2026-09-28 absolute deadline
and only core/clean-job test targets. It cannot build or validate the current
evidence implementation. It was not changed or launched. A future bounded
package must pin the reviewed new source, include all registered Stratum
tests, verify build identity and checksums, and use a fresh absolute deadline.
Do not revive the old workflow by merely extending its deadline.

CMake and Ninja are absent in this session, so full CMake/CTest and CUDA
packaging remain unverified. Existing direct CPU results are not relabeled
as CMake validation. Pool permission, admission, stable/live, CUDA code and
the running rig are unchanged.
