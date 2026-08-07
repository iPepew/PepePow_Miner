# PepeW Miner v1.0.5 development notes

v1.0.5 is a test-focused release under active development. Do not publish it as a stable release until the hardware validation matrix is complete.

## Planned and implemented foundation

- Add native CUDA targets for `sm_70` (Tesla V100 / Volta) and `sm_80` (Ampere datacenter / CMP 170HX class) while retaining `sm_61`, `sm_75`, `sm_86`, `sm_89` and `sm_120`.
- Keep the validated process-per-GPU HiveOS model from v1.0.4.
- Add per-architecture runtime profiles and runtime-selectable CUDA block size.
- Use initial test profiles: Volta and Blackwell start at 512 threads; other supported architectures start at 768 threads.
- Add a compact professional HiveOS console monitor with per-GPU hashrate, temperature, fan, power, clocks, Accepted, Rejected and efficiency.
- Remove emoji and problematic Unicode from runtime output. ANSI colors are optional; runtime text is ASCII-safe.
- Add clear unsupported-architecture diagnostics before mining starts.
- Report CMP unlock state when an external unlocker status file is available. PepeW Miner never changes the NVIDIA driver or unlocks CMP cards automatically.

## Hardware results carried forward from v1.0.4

- RTX 3080: running and submitting accepted shares.
- GTX 1660 SUPER: approximately 0.786-0.797 MH/s.
- CMP 30HX: approximately 0.798 MH/s.
- CMP 50HX: approximately 1.812 MH/s before controlled unlock comparison.
- CMP 90HX: approximately 1.787 MH/s before controlled unlock comparison.
- Eight RTX 5060 Ti cards: approximately 1.40-1.42 MH/s per GPU; multi-GPU telemetry works, performance optimization remains required.
- Tesla V100: v1.0.4 fails because the package lacks `sm_70`; v1.0.5 adds the missing native architecture.

## Optimization work still required

- Establish an unoptimized Tesla V100 baseline, then profile Volta occupancy, registers, spills, block sizes and batch/chunk sizes.
- Compare Tesla V100 results with the external `hoo_gpu` screenshot showing about 26.5 MH/s. This number is a reference, not a verified PepeW Miner target.
- Profile RTX 5060 Ti / Blackwell and tune block size, launch geometry and hot HooHash FP64/transcendental paths.
- Run controlled CMP 50HX and CMP 90HX A/B tests before and after a compatible third-party compute unlock.
- Verify that multi-GPU workers do not duplicate effective pool work and compare local with pool-side hashrate.

## Release gates

A public stable release requires accepted shares, sane rejection rate, correct HiveOS per-GPU statistics, no new NVIDIA Xid errors and hardware testing on Tesla V100, RTX 3080, RTX 5060 Ti and available CMP/GTX cards.
