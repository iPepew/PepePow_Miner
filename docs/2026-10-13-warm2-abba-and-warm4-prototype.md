# Warm2 offline ABBA and warm4 prototype — 2026-10-13

Warm2 source `3b545269cbdf6a9bbb9de37e43b96cb61077dc44` passed CUDA unit/consensus, direct100000 with zero mismatches, and 836 warp scenarios with zero mismatches on RIG-77. GPU run38368257727 finished with an additional recovery-binding postcheck failure; the immediate failure category was not recorded. Independent read-only run38369022294 subsequently confirmed the configured `custom/hoo_xpu`, pinned launcher/script/miner hashes, one main GPU process, and GPU utilization99%. An initialization delay is plausible, not established as the cause.

Comparable ABBA run38369540211 used three Header80 inputs, 16777216 nonces, two warmups, twelve ABBA rows, exact cached packages and identical22 shared build options/container/compiler/benchmark source. Baseline8bd546ba averaged13.6735796667 MH/s; warm2 averaged9.9628721667 MH/s, a27.1377912036% regression. Per-header regressions were27.0155%,27.1719%,27.2257%; candidate repeat spreads were0.0479%,0.0643%,0.0033%. Reject warm2 for performance. These are offline rates, not accepted-share pool hashrate. Pre-row telemetry does not prove absence of throttling under load. Helper recovery and independent main-owner/configuration checks passed after this ABBA.

The installed helper2026-09-14.1/SHA9c48e1f810e08fdce4424532c6bc3bc1e39a67997051b4c1b30cf1870aabec82 restores through /hive/bin/miner start. Current configuration selects MINER=custom and CUSTOM_MINER=hoo_xpu; h-run.sh selects ./hoo_xpu. Disk miner SHA d932159c4e69b6d4d123e4918f351f49a30170741779902fe8aa0ff0b34219af matched root-operator process evidence. Runner /proc access was not expanded or retried. The old repository helper2026-09-01.1 is not the installed source and must not replace it.

Warm4 source `2cdc7804dad1254ffc33764bb279ea1e015904c9`, fusion blob `109369dbcaf98c08a3f409ba834e2ffee6875af2`, stages up to four warm contributions within the packed word, then commits only while SW stays warm and in original order. Both barriers and the completion vote remain intact. The experimental reconvergence flag remains default OFF. CPU model synthetic2520 and Header802520 executions produced20643840 cell-trace comparisons total and zero mismatches; all five existing mutation gates detected their errors. This is CPU-libm/coroutine evidence, not CUDA/libdevice or measured performance. A bounded compile-only audit is separate from source-specific SASS review and cannot assemble a candidate package or grant GPU admission.

No real-pool test, release promotion, stable or production deployment was performed. Machine evidence in PepePow_Lab:
- results/analysis/warm2-gpu-correctness-20261013-075750.json
- results/analysis/warm2-independent-recovery-20261013-075750.json
- results/analysis/warm2-abba-runtime-20261013-075750.json
- results/analysis/warm4-host-model-20261013-075750.json

Next admissible hardware step requires a fresh warm4 build, source-specific SASS rendezvous/call/vote/backedge review, sm70/zero-spill gate, pinned exact package, current exclusive availability and independently bounded watchdog/recovery. Warm4 MH/s is unknown.
