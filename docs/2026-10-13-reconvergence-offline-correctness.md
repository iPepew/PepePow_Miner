# V100 reconvergence offline correctness — 2026-10-13

The exact experimental candidate source `69982736eb073a8df53fbdbe4dc02509fc760807` passed the bounded V100 offline correctness check on 2026-10-13 at 00:44:12 Moscow time (2026-10-12T21:44:12Z).

- Package SHA256: `98e63d4b75dda951b0591346954cc43eab569e7b02d96b191cac15164fe6a713`.
- Miner SHA256: `926e95c596c5f99da0d381fc92b5de4c8d15d6f3ef36ba2825ec977ed8cfe170`.
- CUDA unit and Header80 consensus tests passed.
- Direct differential: 100 headers, 100000 CPU/GPU comparisons, 0 mismatches.
- Partial/full warp batch gate: 16 headers, 836 scenarios, 16208 CPU oracle hashes, 0 mismatches.
- Installed helper watchdog was checked active before GPU load; 180-second exclusive lease, independent GNU timeouts and recovery reserve were enforced.
- `RECOVERY_PASS` confirmed; subsequent helper status reported `active=none` and `miner=live`.

[GPU run 38312221373](https://github.com/iPepew/PepePow_Lab/actions/runs/38312221373) and [exact package transport 38312118135](https://github.com/iPepew/PepePow_Miner/actions/runs/38312118135) completed successfully. The private lab machine report is `results/analysis/reconvergence-gpu-correctness-20261012.json`.

The first attempt passed unit/consensus tests but returned a suppressed CalledProcessError during the extended gate and recovered the miner. Its exit code was not recorded, so the exact failure subtype is unknown. A revised runner added sanitized failure metadata and increased only the direct test limit from90 to130 seconds, retaining the180-second lease and15-second lease margin; the revised complete gate passed. Local timeout/budget/metadata tests:8/8 PASS. Controller timing tests:11/11 PASS.

These are correctness results, not hash throughput measurements. No new MH/s claim, comparable ABBA result, pool share acceptance result or release promotion follows from this test. Experimental CUDA remains default OFF; production/stable/live were not changed. The next hardware step is a bounded comparable offline ABBA against the verified baseline, followed by the applicable pool gate only if improvement is verified.
