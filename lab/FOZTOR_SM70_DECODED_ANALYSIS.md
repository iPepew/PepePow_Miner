# Foztor `hoo_gpu` 1.4.23 — decoded sm_70 clean-room analysis

Target: Tesla V100-SXM2-16GB / PEPEW HooHashV110.

This document records architectural observations only. No Foztor binary or SASS is committed to this repository and no proprietary implementation is copied.

## Live reference

Official `hoo_gpu` 1.4.23, `--pepepow --exp-threshold 1.5`, same V100:

- autotune tested 568 configurations;
- winning launch: `tpb=640`, `blocks=320`, `batch=1228800`, reported tune score 26.510 MH/s;
- sustained live rate approximately 26.2 MH/s at ~1530 MHz core / 877 MHz memory;
- kernel resource line: 47 registers/thread, 272 bytes local;
- cache mode `PreferL1`, shared-memory carveout 0%;
- CPU validation enabled;
- near end of the run: 338 GPU solutions, 2 invalid (0.59%), pool accepted ratio ~99.7%.

PepeW R128 field baseline is ~9.83 MH/s, therefore the implementation gap is ~2.67x.

## Decoded CUDA module

The runtime `cuModuleLoadData` capture produced a valid non-stripped CUDA ELF for sm_70, 104,544 bytes.

Important sections:

- `.text.pepew_mining_kernel`: 31,104 bytes;
- `.nv.shared.pepew_mining_kernel`: 128 bytes;
- `.nv.constant2.pepew_mining_kernel`: 296 bytes;
- `.nv.constant0.pepew_mining_kernel`: 384 bytes;
- `.nv.constant3`: 33,216 bytes.

The `.text.pepew_mining_kernel` ELF `sh_info` high byte is `0x2f`, confirming 47 registers/thread independently of the miner log.

## PEPEW constant state

The decoded symbol table exposes the following PEPEW job-wide state:

- `c_Target` — 32 bytes;
- `const_mat` — 32,768 bytes exactly, i.e. a full 64x64 FP64 HooHash matrix;
- `d_exp_threshold` — FP64 scalar;
- `c_PepewHdr76` — exactly 76 bytes;
- `c_start_nonce`;
- `c_pepew_nonce_base`;
- `c_div_uv_d` — 128 bytes.

This is strong evidence that Foztor does not reconstruct an 80-byte header per nonce. The invariant PEPEW prefix is resident as a 76-byte constant and only the nonce tail varies.

The 32 KiB `const_mat` symbol confirms that the optimized sm_70 PEPEW path keeps the complete matrix in constant address space.

## External lookup state

The cubin also contains relocations/pointers for:

- `d_exp_lut_dl16k`;
- `d_exp_sincossum_lut`;
- `d_sin2_lut`;
- CUDA sin/cos coefficient and 2/pi range-reduction data.

The runtime log separately reports:

- `Building magic numbers (768 KB)`;
- `Initializing fallback magic (128 KB)`.

Since HooHash has 4096 matrix cells, 768 KiB / 4096 = 192 bytes/cell and 128 KiB / 4096 = 32 bytes/cell. This strongly suggests job-specific per-matrix-cell precomputation feeding the nonlinear/range-reduction path rather than recomputing every expensive FP64 transformation from first principles for every nonce.

This inference is architectural, not a claim about Foztor source code.

## Embedded function structure

The decoded module exposes these local functions in the PEPEW text section:

- `compress_pre` — 5,216 bytes;
- `blake3_cuda_32` — 2,400 bytes;
- `__internal_trig_reduction_slowpathd` — 2,432 bytes;
- `blake3_pepew_header80` — 4,448 bytes;
- `pepew_phase1_prep` — 1,248 bytes;
- global `pepew_mining_kernel` — 31,104 bytes.

There is no separately exported nonlinear HooHash function; the hot transform is therefore substantially inlined into the mining kernel.

The presence of `blake3_pepew_header80` together with `c_PepewHdr76` indicates a PEPEW-specific first-hash implementation rather than a generic local `header[80]` pipeline.

## Math constants

The per-kernel constant section includes values matching the HooHash/trig domain, including:

- `2.5e-7` (`1e-6 / 4`);
- `0.66`;
- pi/2, pi, 2*pi, 2/pi;
- double-precision trig polynomial/range-reduction coefficients;
- sqrt(2).

The decoded module therefore still contains an exact/slow trig fallback. The performance advantage is not explained by simply replacing all FP64 math with low-precision float operations.

## What this changes for PepeW

The current PepeW R128 path remains structurally expensive:

1. one complete nonce per thread;
2. generic per-nonce BLAKE3 materialization;
3. strict 64x64 serial matrix walk;
4. direct FP64 transcendental calls on the hot nonlinear branch;
5. much larger register footprint than the Foztor sm_70 kernel.

The clean-room target architecture should therefore be:

### A. PEPEW-specialized header path

- store bytes 0..75 job-wide;
- precompute the BLAKE3 state for the invariant first 64 bytes;
- calculate only the final 16-byte BLAKE3 block per nonce;
- keep first/final hash state as eight 32-bit words instead of byte arrays.

### B. Lower live state

- retain streamed two-row output generation;
- avoid `double product[64]`, `uint8_t vector[64]`, and local `header[80]`;
- target natural compiler allocation close to the observed 47-register reference instead of forcing a high register cap as the primary tuning mechanism.

### C. Matrix placement

- use 32 KiB constant memory for the 64x64 FP64 job matrix;
- benchmark only after the rest of the hot-state reduction is in place; the previous isolated PepeW constant-memory experiment mixed several changes and regressed.

### D. Nonlinear accelerator

Build independent job-specific precomputation for the expensive nonlinear path:

- exact strict path remains available for KAT/differential verification;
- fast path uses precomputed per-cell range-reduction data and lookup tables for the periodic `exp(sin+cos)` and `sin^2` branches;
- retain an exact trig slow fallback for cases outside the fast precomputation domain;
- expose a lab threshold controlling fast-path aggressiveness;
- CPU-validate every GPU candidate before Stratum submission;
- measure both invalid GPU candidates and lost/effective accepted-share rate.

A naive FP32 replacement is explicitly rejected because BLAKE3 avalanche means small HooHash numeric errors would invalidate essentially all candidate hashes.

### E. V100 launch/autotune

Use Foztor's measured launch only as a search anchor, not as a copied implementation:

- include 640 threads/block in the Volta sweep;
- search block count / internal nonce-loop / batch combinations around the measured 320 blocks / 1,228,800 work-item reference;
- set `cudaFuncCachePreferL1` and 0% shared-memory carveout for the V100 candidate;
- cache the result by GPU architecture/device name.

## Next implementation gate

Do not promote a candidate on raw MH/s alone.

Required gates:

1. startup real-block KAT PASS in strict mode;
2. deterministic GPU-vs-CPU corpus for strict path;
3. fast-path candidate CPU validation before submit;
4. 5-minute V100 A/B against 9.83 MH/s;
5. report raw scan MH/s, invalid-candidate rate, accepted/rejected shares and effective accepted rate;
6. no CUDA/Xid errors;
7. only then run a 20-minute soak.

The immediate engineering objective is a new sm_70 experimental kernel that combines PEPEW header specialization, low live state, constant matrix placement and a validated nonlinear fast path. Further register-cap-only experiments are no longer a priority.
