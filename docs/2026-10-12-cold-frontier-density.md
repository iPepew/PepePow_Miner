# Cold-frontier density on host — 2026-10-12

Candidate source: 69982736eb073a8df53fbdbe4dc02509fc760807; experimental default OFF.

The existing coroutine scheduling checker now records pending lanes immediately before the cold-call frontier. The histogram must conserve the number of actual candidate nonlinear calls, and each matrix/mask histogram must be invariant under forward, reverse and rotating lane execution. A fifth destructive mutation corrupts the pending observer; it must fail the conservation check while numerical traces otherwise remain intact.

Two input families are reported separately:
- Existing synthetic edge-case first-pass inputs: 2520 hashes / 192 batches.
- Header80 fixtures built by the pinned production header_builder.cpp using the benchmark job patterns: another 2520 hashes / 192 batches. First-pass and nonce-zeroed matrix seed use pinned portable BLAKE3 1.8.5. Its official empty-input KAT is checked. Mixing nonce is independently decoded LE32 from the builder's BE32 nonce bytes; signed-boundary and final-uint32 ranges are included.

The runner can add the fixture family with:
`timeout -k 5s 240s python3 scripts/ci/check_reconvergence_host.py --blake3-root /path/to/BLAKE3/c`.
It verifies five CUDA/oracle blobs, five Header80 protocol/source blobs and five BLAKE3 dependency blobs. Dependencies are not vendored into the miner.

Hosted run 38295998845 (job 114967102705, workflow commit 7ab9585713e80d40c222ef88482e9b2e34d41495) PASS. Both families have zero per-cell trace / SW-mode3 predicate / mixed-byte mismatches, and all five mutants are detected.

For full 32-member warps on Header80 fixtures:
- 5226 nonempty cold frontiers, 96387 pending cold calls.
- Mean pending lanes per nonempty frontier: 18.4437428243.
- 1707 frontiers (32.6636%) have 1–4 pending lanes; those contain 3732 calls (3.8719% of pending calls).
- 2043 frontiers (39.0930%) have all 32 pending lanes; those contain 65376 calls (67.8266%).
- There are 24 final zero-pending frontiers, reported separately and excluded from these averages.

Synthetic edge-case inputs have mean 15.5495 pending lanes; their deliberately all-zero lanes make them unsuitable as a throughput proxy. Header80 benchmark fixtures are deterministic test inputs, not captured pool jobs. Each family's 2520 hash executions include replays across masks and three execution orders. The Header80 family contains 256 distinct header/nonce pairs; its full-warp histogram covers eight distinct 32-lane groups replayed three times. It is not a sample of 2520 independent pool inputs.

## Interpretation and limits

These counts validate the proposed gathering behavior in the host scheduling model and expose a sparse completion tail. They count entry into the outer cold nonlinear call, not CUDA/libdevice's internal branch/subroutine lane density, SASS instruction executions, GPU occupancy or elapsed time. CPU libm and a positive-finite intrinsic shim remain in use. No MH/s result or improvement is established.

Dropping already-completed lanes from the membership mask alone cannot add pending cold tasks to a frontier. These counts therefore do not provide a throughput admission for a separate mask-shrinking kernel. No additional runtime variant is introduced from this observation.

The next material check remains actual bounded GPU correctness, then comparable offline ABBA for the existing candidate. The package-transfer authorization blocker remains unresolved; no denied release operation or GPU job is retried here.
