# Warm4 exact GPU gate and offline regression — 13 October 2026

Source: `456d231069060ae28ef4fe23e6ddf383ec0687a1`; its native tree is identical to warm4 prototype `2cdc7804dad1254ffc33764bb279ea1e015904c9`, fusion blob `109369dbcaf98c08a3f409ba834e2ffee6875af2`. The newer metadata source includes the manual-only Protocol Probe fix. Experimental reconvergence remains disabled by default.

The exact package [build 38372884521](https://github.com/iPepew/PepePow_Miner/actions/runs/38372884521) passed 7 registered CPU tests, sm70, zero spills and the eight reviewed ordered BSSY/BSYNC/call/vote/return/backedge fragments. Resources: 50 registers, 80-byte stack, 1,950 kernel SASS instructions. All 22 shared configuration options, GNU 11.4.0, CUDA 12.8.93 and container digest match the reference build.

| Object | SHA-256 |
|---|---|
| Package tarball | `2a5804e33610fb22bba648b0e48cf693a09a82a04b426ff117085486fdc58883` |
| Miner | `6516e13925ee785ab72604cb47a2df5974c1f5fc2af34418619168ae5df577aa` |
| Header80 benchmark | `773da7d834ff2a472650781bfdc8f72f78b5a0c0781a8c62a9b31aa390e7618f` |
| Header80 differential | `dd3b53ac3d92904aba716b3a823f44daf77b3a03156072b705ad6d56641c2039` |

## GPU correctness and recovery

Exclusive correctness run38373515599 (controller38373494432) passed CUDA unit/Header80 consensus, direct100000/0 mismatches, and warp836/16208 CPU-oracle hashes/0 mismatches. All package checksums and source identity were verified before lease acquisition. The installed helper and configured recovery binary/launcher/script hashes were verified before and after; independent recovery timer was active before GPU load. Lease180, independent command timeout, absolute session deadline09:53:23Z and recovery reserves applied. Main owner changed from PID3885909 to PID4002741 during successful recovery; the exact disk hash and configured launch selection remained pinned. No denied /proc read, privilege expansion or pool connection was attempted.

Temporary public-source package transport38373360366 completed successfully; its prerelease and tag were removed, with release endpoint404 confirmed. This was temporary transport, not a formal miner release.

## Comparable offline ABBA

Run38373914084 (controller38373897854), three Header80 inputs, 12 ABBA rows, 16,777,216 measured nonces and two warmups per process. Both cached tarballs, SOURCE.env, complete checksums and benchmark hashes were verified. Reference source `8bd546ba2b899f3aafdf9c31a34c3068332bf865`.

| Header | Baseline MH/s | Warm4 MH/s | Change |
|---|---:|---:|---:|
| 0 | 13.563482 | 9.9603445 | −26.56499% |
| 1 | 13.673130 | 9.9544715 | −27.19683% |
| 2 | 13.688351 | 9.9528745 | −27.28946% |
| Mean | 13.6416543 | 9.9558968 | −27.01841% |

**REJECTED_PERFORMANCE_REGRESSION.** Correctness PASS does not establish performance admission. Every header regressed. Warm4 is close to the previous warm2 9.962872 MH/s observation, but separate sessions and operating variation do not prove equivalence or a precise cross-session gain. Baseline repeats varied up to0.7644%; candidate repeats up to0.1501%. Telemetry was captured before each row; under-load clocks/throttling were not established. These are offline Header80 rates, not accepted-share pool hashrate, and do not confirm 13.686 MH/s on a live pool.

ABBA recovery passed, configured hashes remained pinned, and main GPU owner PID4010960 was confirmed. Stable/live and formal release were not changed.

## Small CPU frontier diagnostic

`scripts/ci/check_warm_width_frontier.py` compares the pinned actual warm2/warm4 CUDA bodies using the existing coroutine harness and Header80/BLAKE3 fixtures. Two full-warp Header80 cohorts per variant: 64 hashes each, 524,288 total per-cell trace comparisons, zero mismatches. Nine shared helper/fixture source blobs match between variants. Exact ordered pending masks and batch lengths match:254 and205 rendezvous, 8,334 nonlinear calls, 29,376 barrier arrivals and14,688 vote arrivals. Pending-mask sequence SHA256 `3ce68ca9679680e2c0389b07f19b2f313952eebd351c4c3062c73260d69b2b9f`.

This CPU-libm diagnostic is not CUDA/libdevice scheduling, dynamic instruction/cycle attribution or a speed estimate. Increasing warm preload width does not change the modeled next-cold trajectory. Do not schedule warm8 merely on the expectation of fewer rendezvous or greater cold-mask density. A new candidate needs measured attribution of warm-loop versus rendezvous/nonlinear costs; counterless bounded source instrumentation is available as an independent direction. Existing hardware-counter admission remains unresolved and was not retried or bypassed.

Machine build, correctness, ABBA and frontier reports are saved in PepePow_Lab `results/analysis/*-20261013-085323.json`. Workflows were restored to manual-only after completion.
