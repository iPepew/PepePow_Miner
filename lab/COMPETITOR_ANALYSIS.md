# PepeW V100 Kernel-v2 performance plan

## Confirmed field baselines

- PepeW strict R128 path: approximately 9.6-9.8 MH/s on Tesla V100-SXM2-16GB in live HiveOS testing.
- Public hoo_gpu field comparison on the same V100 class: approximately 26.05 MH/s.
- Target for PepeW: first close the ~2.6x implementation gap, then pursue 30 MH/s.

## Why the old strategy is no longer sufficient

The current CUDA implementation assigns one complete nonce to one CUDA thread. That thread owns the full fixed-header BLAKE3 calculation, a 64-element double product array, the complete serial 64x64 HooHash matrix traversal, the nonlinear FP64 path, and the final BLAKE3. R128 improved occupancy, but it does not change this architecture.

The strict HooHash reference exposes several exact optimizations:

1. `sw` is declared outside the 64-row loop and is therefore carried from the end of row N into the first operation of row N+1. Rows are **not fully independent** in the strict algorithm. A naive warp-per-row rewrite would be consensus-incorrect.
2. Only the current row product is needed while traversing a row. After two consecutive rows finish, their low-byte combination can be emitted immediately. The current `double product[64]` array is unnecessary; strict execution can stream the rows with two scalar FP64 accumulators while preserving the carried `sw` dependency exactly.
3. The first 64 bytes of the 80-byte PEPEPOW header are invariant across all nonces of a job. Their BLAKE3 chaining value can be precomputed once per job.
4. Header bytes 64..75 are invariant. Only the nonce word in bytes 76..79 changes during scanning.
5. Each first-pass hash byte becomes two 4-bit vector elements. The hot path does not need a separate `uint8_t vector[64]`; the nibble can be extracted on demand.

## Kernel-v2 architecture

### Stage 1: strict streamed-state matrix path

First remove state, without changing a single mathematical operation or its order:

- eliminate `double product[64]`;
- process row 0 then row 1, immediately emit scaled byte 0; continue in row pairs;
- preserve one `sw` scalar across all 64 rows exactly as the reference does;
- eliminate `uint8_t vector[64]` by extracting nibbles from the first-pass hash on demand;
- keep the nonlinear operation order bit-exact.

This attacks the current 640-byte hot-kernel stack/local-memory footprint without introducing consensus risk.

### Stage 2: fixed-header BLAKE3 specialization

Precompute once per job:

- BLAKE3 CV after header bytes 0..63;
- constant words for header bytes 64..75;
- HooHash matrix;
- target words.

For each nonce, calculate the first pass from the precomputed CV plus only the final 16-byte block. Do not build an 80-byte local header. This removes one entire BLAKE3 compression from every scanned nonce.

### Stage 3: keep first-pass state in words/registers

Remove or minimize the remaining local arrays:

- `uint8_t header[80]`;
- `uint8_t vector[64]`;
- `double product[64]`;
- temporary 32-byte arrays where eight 32-bit words plus direct nibble extraction/shuffles can replace them.

The objective is near-zero local-memory traffic and a substantially smaller stack frame on sm_70.

### Stage 4: parallel/speculative HooHash research

Because strict `sw` links rows, row-parallel execution requires more care than simply assigning rows to lanes. Candidate research paths:

- two-state speculative row evaluation: each row can be considered a transition from incoming `sw<=0.02` state to an outgoing state; investigate parallel prefix/composition and select the strict path afterward;
- interleave several independent nonces per warp to hide long FP64 transcendental latency while retaining exact per-nonce row order;
- compile-time workload variants tuned separately for Volta.

No cooperative rewrite is promoted until it matches the CPU reference across a large deterministic corpus.

### Stage 5: strict and experimental nonlinear paths

Maintain two explicit modes:

- `strict`: bit-exact HooHash V110; must pass differential tests against the CPU reference.
- `fast-lab`: experimental reduced-FP64 path. It is never promoted until its invalid/lost-solution rate is measured against strict mode on a large deterministic corpus and real pool shares.

Do not call an approximate path a hashrate improvement unless effective accepted-share rate also improves.

### Stage 6: architecture autotune

Autotune on each GPU architecture and cache the result:

- threads/block and active nonce count;
- batch/workload size;
- register caps around the natural compiler allocation;
- optional multi-nonce interleave factor;
- blocking sync versus active polling if host overhead becomes visible;
- strict versus explicitly opt-in experimental solver parameters.

For sm_70, the autotune score must combine effective strict hashrate, accepted/rejected/invalid shares, power, temperature, clocks and zero CUDA/Xid errors.

## Validation gates

Every candidate must pass, in order:

1. CPU/GPU consensus KAT.
2. Differential corpus: thousands of deterministic nonces against CPU HooHash reference.
3. 5-minute A/B performance test with fixed PL and clocks.
4. 20-minute soak test for any promoted baseline.
5. Real accepted-share validation and effective poolside rate.
6. Multi-GPU HiveOS telemetry validation.

## External evidence to investigate

The public hoo_gpu release history points to the same broad optimization areas:

- architecture-specific fatbins;
- dedicated Volta/Turing performance work;
- reduced FP64 calculations;
- large later gains on NVIDIA datacenter GPUs;
- GPU autotuning and cached tuning results;
- strong dependence on core clock and low dependence on memory clock;
- an explicit speed/incorrect-calculation tradeoff exposed by its `--exp-threshold` option.

The `hoo-gpu-binary-analysis.yml` workflow downloads several public official releases and inspects their CUDA payload/resource metadata. No third-party binary is committed to this repository.
