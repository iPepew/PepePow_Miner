# First-pass local input cache experiment (2026-10-12)

Default OFF: `PEPEPOW_CUDA_FIRST_PASS_LOCAL_CACHE`. Only the hotrun8 local-phase kernel changes when enabled: it copies the eight first-pass words into an address-stable per-thread array and passes that pointer to the existing noinline mixer. The mixer function, matrix/FP64 math, SW transitions, combination order, final BLAKE3 and target logic are unchanged. The hypothesis is that repeated input reads may benefit from local-memory layout/cache behavior; no speedup is assumed.

With the flag OFF, preprocessed CUDA tokens (ignoring whitespace only) match source `62a9ef3` under local-phase production flags. This does not prove generated-code identity; compile resources must be checked. With the flag ON, the added 32 bytes of per-thread input state can instead increase stack traffic and reduce performance. It is an experimental candidate, not a default or release promotion.

Required evaluation: exact-source sm70 build and zero compiler spills, CPU/replay gate, bounded CUDA unit/Header80 consensus and new direct differential gate, then comparable offline ABBA against the pinned ordinary `8bd546ba` package. All GPU windows require fresh exclusivity, helper hash/watchdog/recovery and absolute deadlines. No pool or production promotion follows merely from nominal benchmark throughput.
