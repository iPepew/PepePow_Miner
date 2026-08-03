# v2.0.0 Warp-Service Campaign

## Why this branch exists

v1.0.0 confirmed a hard plateau around 1.5569 MH/s at 1650 MHz. Pointer
walking and 32-bit SW predicates changed throughput by only 0.02%.

The measured bottleneck is sparse nonlinear execution under heavy warp
divergence: only about 3.18% of lanes enter the cold path, while more than
63% of warp steps are divergent.

## Architecture under test

The experimental kernel compacts all cold tasks from a CUDA block into one
shared-memory queue. A single service warp executes the expensive
`sin/cos/exp/sqrt` work for the packed tasks, writes results back to their
owners, and the worker threads continue with consensus-exact state.

The campaign tests 64, 128, 256, and 512-thread blocks, inline and noinline
nonlinear code, plus a fresh exact zero-nibble fast path.

## Safety gates

Every profile must pass:

- all CTest targets;
- CPU/CUDA header80 validation;
- no CUDA spills;
- repeatable benchmark runs.

A candidate needs at least 0.5% offline uplift before stress and
compute-sanitizer. Nothing is installed and no stable miner is restarted.

The 2 MH/s target is not declared reached until a later live pool test has
Accepted > 0, Rejected = 0, no CUDA errors, and no new NVIDIA Xid.
