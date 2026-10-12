# Sampled local-phase substage timing (2026-10-12)

`PEPEPOW_CUDA_SUBSTAGE_TIMING` defaults OFF. It requires the admitted split hotrun8/fusion2/local-residency/runtime-local-phase path. In diagnostic builds, lane 0 in the first 1024 blocks records elapsed SM cycles before the noinline HooHash mixer, after its return, and after final BLAKE3. The samples are written before target filtering, so they do not select only successful nonces. No matrix, FP64, SW transition, hash or target arithmetic is changed.

After the kernel completes, the host reads at most 16 KiB and prints `CUDA_SUBSTAGE_TIMING` numeric summaries (sample count, mixer/final mean/min/max). Each invocation overwrites the slots used for that invocation; only those slots are read. Launches with fewer than 1024 blocks read only their block count. Zero work is handled by the existing early return. Final BLAKE3 timing excludes target checking and publication.

These are elapsed per-thread SM cycles, including time slicing, rather than instruction cost or whole-kernel wall time. Sampling branches, additional live clock registers, and storage can alter generated code and occupancy. The first 1024 block-leading lanes are a bounded diagnostic sample, not exhaustive input coverage. SASS clock/mixer-call ordering and diagnostic resources must be inspected before interpreting a run. This mode must not be used as a production performance candidate, pool test, or proof of an uninstrumented speedup.

With timing OFF, preprocessing of both changed CUDA fragments matches the preceding source under production flags. A CUDA compile and runtime correctness check are still required for the diagnostic build; preprocessing alone is not that check.

Reference: [NVIDIA CUDA Programming Guide, time functions](https://docs.nvidia.com/cuda/archive/12.3.1/cuda-c-programming-guide/index.html#time-function).
