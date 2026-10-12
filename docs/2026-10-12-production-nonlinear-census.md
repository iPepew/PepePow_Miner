# Bounded production nonlinear census (2026-10-12)

`PEPEPOW_CUDA_NONLINEAR_CENSUS` defaults OFF. It instruments the actual Header80 nonlinear function, preserving the current selector decode, parenthesized FP64 transforms, exact fixed-window sincos, and result expressions. No copied legacy probe or approximation replaces those expressions.

For the first 128 blocks, each nonlinear invocation increments exactly one region counter (exp/sincos, sin squared, inverse sqrt). Trigonometric invocations also classify the actual transformed argument's unbiased exponent into below31,31..56,or other. Division-transform invocations are counted separately. At function entry, the current active execution mask is sampled; its elected first lane records the group and active lane count. This uses no new synchronization. These are active execution groups at that instruction, not a complete algorithmic divergence model: Volta independent thread scheduling and instrumentation can alter group fragmentation.

Counters reset before each Header80 search and are read after its completion. Host checks require region counts to partition all sampled lane entries, trig buckets to partition both trig regions, and group/division counts to lie within invocation totals. The mode assumes one sequential backend search; overlapping host searches would race the global counter reset/read.

Atomic instrumentation and possible register/code changes can distort timing. Counts describe this bounded sample; they do not establish time percentages or production speed. The mode is restricted to offline diagnostic use, not pool or promotion. The intended configuration is the ordinary admitted hotrun8/fusion2/local-phase pipeline with the experimental first-pass cache OFF and both timing modes OFF. GPU unit and Header80 consensus must pass, counter partitions must hold, and every run requires independent watchdog and verified recovery.

Census OFF preprocesses identically to the preceding CUDA fragments under the tested production flags. This is a source check, not a GPU execution claim.
