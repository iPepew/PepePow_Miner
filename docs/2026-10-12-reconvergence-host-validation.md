# Host scheduling validation for cold reconvergence — 2026-10-12

Candidate: 69982736eb073a8df53fbdbe4dc02509fc760807, experimental default OFF.

Run: `timeout -k 5s 180s python3 scripts/ci/check_reconvergence_host.py`.

The checker verifies four exact Git blob identities, extracts the actual candidate CUDA function and its nibble/scaled-table helpers, and replaces only the collective interface with C++20 coroutine awaits. The candidate's loop/row/column advancement, pending-cell arithmetic, ordered accumulation and mixed-word packing are retained.

The independent sequential oracle is the pinned production CPU hoohash_reference.cpp. A trace hook after its unchanged SW update records the FP64 bits of the row accumulator and SW fraction after each cell. All 4096 records and all 32 mixed bytes must equal the candidate's host execution for every lane.

The collective dispatcher enforces two barrier slots and one completion vote per round, identical member masks, and cohort completion. Finished lanes must remain in collectives while another member is unfinished. It executes lanes forward, backward and with rotating order. Eight matrix seeds cover prefix masks of 1/2/17/31/32 lanes and sparse masks, random first-pass values, all-zero/all-15 nibbles, alternating nibbles and bit patterns, and nonce values crossing the signed boundary or descending from UINT32_MAX.

Coverage contract: 192 batches, 2520 hashes, 10,321,920 cell trace comparisons. Three separately compiled destructive mutants must fail for the intended reason: missing second barrier, early exit of a finished lane, skipped zero-nibble state update.

## Limits

CPU libm substitutes for CUDA/libdevice nonlinear math; the host adapter uses the production reference SW fraction formula rather than the encoded GPU SW helper. This proves host-model per-cell order/value consistency and collective participation for these inputs. It does not prove GPU barrier execution, CUDA rounding/codegen/libdevice equivalence, full Header80/final BLAKE correctness, throughput or pool acceptance. All GPU gates remain closed until actual bounded hardware validation. No release or production setting is changed.
