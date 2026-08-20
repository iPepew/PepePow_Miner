# Foztor hoo_gpu 1.4.23 — V100/PEPEW findings

External performance reference for PepeW V100 work: **Foztor hoo_gpu only**.

Observed from the user-supplied 1.4.23 Linux binary/package and the official Foztor release notes:

- dedicated per-architecture cubins, including `hoo_gpu_sm70.cubin` for Volta;
- dedicated `pepew_mining_kernel` and PEPEW header symbols rather than only a generic HTN path;
- CUDA Driver API module loading and per-device autotune;
- autotune dimensions include TPB, blocks, batch, warp/oversubscription, shared memory, cache preference and carveout;
- job/runtime symbols include `c_PepewHdr76`, `c_pepew_nonce_base`, `const_mat`, `const_mat_f_h`, `const_mat_f_l`, `d_mat_fp64_gbl`, `d_secondary_magic`;
- optimized exp LUT and `d_exp_sincossum_lut` support;
- TransformFactor LUT support;
- CPU validation of GPU candidates and explicit PEPEW validation-failure accounting;
- tunable `--exp-threshold`, trading GPU speed against incorrect calculations;
- strong sensitivity to core clock and recommendation to minimize memory clock;
- official release history reports reduced FP64 work and large data-centre GPU gains.

Implication for PepeW:

The 9.8 MH/s R128 path is not expected to reach the 30 MH/s target through register/block/batch tuning alone. The next implementation track must specialize for SM70/PEPEW and reduce exact per-nonce FP64/transcendental work while retaining exact validation before share submission.

Live Foztor measurement on the same Tesla V100 is required before selecting the next kernel geometry. Use `lab/foztor-v100-live-benchmark.sh` and preserve its autotune, GPU telemetry and validation report.
