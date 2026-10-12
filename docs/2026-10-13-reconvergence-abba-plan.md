# Prepared offline ABBA comparison — 2026-10-13

This plan has not been executed. It compares correctness-passed reconvergence source `69982736eb073a8df53fbdbe4dc02509fc760807` with the previously measured baseline `8bd546ba2b899f3aafdf9c31a34c3068332bf865`.

The benchmark source is identical for both versions: Git blob `984fe247f231c70a5046b29845ad581485e3f8c3`. Candidate benchmark binary SHA256 `701b62855925156dab3634f468e255d703b9c64e1a982807cd9b0c564d975ce5` is recorded by hosted build38271073899/job114885174141. Baseline benchmark SHA256 is `0dfd2efceca1b113c289bb76e90884f090b03a6f6ccaab31a1f396607128c8ff` in the successful historical ABBA runner.

Contract: headers0/1/2; ABBA per header;16777216 measured nonces from65536;2 warmup launches of65536 nonces from0 per process; impossible zero target;12 measured rows. Record raw timings, both A/B samples per header and variability. These are offline end-to-end Header80 measurements, not accepted-share pool rates.

Before dispatch, verify fresh status, cache presence and every pinned package/binary/checksum; baseline compiler flags must match the candidate except the deliberate reconvergence experiment. Equal benchmark source alone does not prove equal compiler flags. Candidate stage/substage timing, census and first-pass-local-cache are OFF; reconvergence is ON. Baseline configuration parity and current cache presence remain unverified.

Use independent GNU command timeouts, the180-second exclusive lease/watchdog, absolute session deadline with late-queue guard,15-second lease margin and90-second session recovery reserve. The older first-cache ABBA runner's Python-only helper timeouts need the already-tested independent timeout wrapper before reuse. Keep promotion disabled; pool/release need their separate gates.

Machine manifest: `iPepew/PepePow_Lab/results/analysis/reconvergence-abba-plan-20261013.json`, commit `c04f93b11c21c33b1cc884677ff2be30ab2f65cb`. Local validation checked digest formats, the12-row contract and reproduced the historical ABBA gain from raw rows. No new GPU job or hashrate measurement was performed.
