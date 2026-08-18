# PepeW V100 Kernel-v2 performance plan

## Confirmed field baselines

- PepeW strict R128 path: approximately 9.6-9.8 MH/s on Tesla V100-SXM2-16GB in live HiveOS testing.
- Public hoo_gpu field comparison on the same V100 class: approximately 26.05 MH/s.
- Target for PepeW: first close the 2.6x implementation gap, then pursue 30 MH/s.

## Why the old strategy is no longer sufficient

The current CUDA implementation assigns one complete nonce to one CUDA thread. That thread owns the full fixed-header BLAKE3 calculation, a 64-element double product array, the complete serial 64x64 HooHash matrix traversal, the nonlinear FP64 path, and the final BLAKE3. R128 improved occupancy, but it does not change this architecture.

The public HooHash reference exposes important structure that should be exploited:

1. The 64 output matrix rows are independent. Only the 64 `j` operations *within one row* are sequential because `sw` depends on the accumulated product for that row.
2. The first 64 bytes of the 80-byte PEPEPOW header are invariant across all nonces of a job. Their BLAKE3 chaining value can be precomputed once per job.
3. Header bytes 64..75 are also invariant. Only the nonce word in bytes 76..79 changes during scanning.
4. Each hash byte becomes exactly two 4-bit vector elements. The vector does not need a 64-byte local array; nibbles can be generated from the first-pass words on demand.
5. `product[64]` is the dominant per-thread state in the current design. Cooperative row processing can replace it with a few double accumulators per lane.

## Kernel-v2 architecture

### Stage 1: fixed-header BLAKE3 specialization

Precompute once per job:

- BLAKE3 CV after header bytes 0..63.
- Constant words for header bytes 64..75.
- HooHash matrix.
- Target words.

For each nonce, calculate the first pass from the precomputed CV plus only the final 16-byte block. Do not build an 80-byte local header.

### Stage 2: cooperative matrix kernel

Implement compile-time variants with cooperative groups per nonce:

- 8 lanes / nonce: 8 rows per lane.
- 16 lanes / nonce: 4 rows per lane.
- 32 lanes / nonce: 2 rows per lane.

The first implementation should use 32 lanes per nonce on sm_70. Lane `L` owns rows `2*L` and `2*L+1`, so each lane keeps only two FP64 accumulators and two `sw` values. The 32 lanes naturally produce the 32 scaled output bytes needed by the final BLAKE3.

### Stage 3: eliminate local-memory arrays

Remove from the hot path:

- `uint8_t header[80]`
- `uint8_t vec[64]`
- `double product[64]`
- temporary 32-byte arrays wherever registers/shuffles can replace them

The objective is near-zero stack/local memory in the mining kernel.

### Stage 4: strict and experimental nonlinear paths

Maintain two explicit modes:

- `strict`: bit-exact HooHash V110; must pass differential tests against the CPU reference.
- `fast-lab`: experimental reduced-FP64 path, never promoted until its invalid/lost-solution rate is measured against strict mode on a large deterministic corpus and real pool shares.

Do not call an approximate path 'hashrate improvement' unless effective accepted-share rate also improves.

### Stage 5: autotune instead of fixed launch geometry

Autotune on each GPU architecture and cache the result:

- lanes per nonce: 8 / 16 / 32
- block size: 128 / 256 / 512 where legal
- batch/workload size
- register caps around the natural compiler allocation
- blocking sync versus active polling if host overhead becomes visible

For sm_70, the autotune score must combine strict hashrate, accepted/rejected shares, power, temperature and zero CUDA/Xid errors.

## Validation gates

Every candidate must pass, in order:

1. CPU/GPU consensus KAT.
2. Differential corpus: thousands of deterministic nonces against CPU HooHash reference.
3. 5-minute A/B performance test with fixed PL and clocks.
4. 20-minute soak test for any promoted baseline.
5. Real accepted-share validation.
6. Multi-GPU HiveOS telemetry validation.

## External evidence to investigate

The public hoo_gpu release history points to the same areas:

- architecture-specific fatbins;
- dedicated Volta/Turing performance work;
- reduced FP64 calculations;
- large later gains on NVIDIA datacenter GPUs;
- GPU autotuning;
- strong dependence on core clock and low dependence on memory clock.

The `hoo-gpu-binary-analysis.yml` workflow downloads several public official releases and inspects their CUDA payload/resource metadata. No third-party binary is committed to this repository.
