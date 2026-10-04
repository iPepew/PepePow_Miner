# Opt-in Stratum evidence and checked response IDs

Base: `509c829636f8a2a11ccfe44c1b59111618595f77` on the experimental
`agent/demand-sliced-batch-correctness-20260917` branch. No pool permission,
release promotion or performance improvement is implied.

## Interface and lifecycle

The production console accepts `--stratum-evidence PATH`. It creates a new
owner-only (0600) JSONL file with exclusive creation: existing files and
symlinks are refused. Default operation creates no evidence file. Use a
regular local filesystem, a unique path per process, and the existing
bounded execution/recovery wrapper. This option does not impose a miner
timeout or authorize a pool connection.

The portable Client exposes `set_evidence_handler` and `finish_evidence`.
Install the handler before run/submit, and finalize exactly once after run
returns and all submit workers have stopped/joined. The console does this
after `worker.stop()`. A handler receives one newline-terminated JSON object
per call; calls are serialized, synchronous, and must not call back into the
Client. It must report write failure by throwing. The first exception disables
the evidence channel and increments `Stats::evidence_errors`; share accounting
continues. A failed channel has no final record. The console reports an
incomplete-evidence error on shutdown. File close errors also fail shutdown.

Synchronous output can perturb timing. No power-loss durability, raw wire
capture, authenticated provenance, or zero overhead is claimed. Custom sinks
must provide bounded behavior; an arbitrary blocking callback is not safe for
a hardware test. The file helper is POSIX, like the existing console application.

## JSONL v1

Every event contains `schema=pepew-stratum-evidence-v1`, contiguous `seq`,
nondecreasing `monotonic_us` since Client construction, and `connection_epoch`.
The epoch starts at zero and increments for each successful TCP connection.
Timestamps mark local event emission, not wire arrival or pool receipt.

Events:

- `stream_start`, `connection_open`, `connection_close`, `stream_end`.
  End includes accepted, inclusive rejected, temporal_stale, reconnects,
  and evidence_errors. It is a snapshot after workers finish, not proof that
  every attempted share received a response.
- `job`: SHA256 `job_ref` and boolean `clean`.
- `submit_attempt`: `submit_id`, `job_ref`; recorded when registering a
  pending submit, before sending. It is not proof of successful transmission.
- `submit_failed` and `submit_discarded`: terminal unresolved outcomes,
  never accepted/rejected pool responses.
- `response`: ID, matched flag, result/error JSON types, boolean result
  (or null), and numeric array error code (or null). Matched responses also
  carry job_ref, effective success, classification, and `clean_ref` (zero if
  not invalidated). Repeated/unknown IDs are observable but never counted twice.
- `temporal_attribution`: ID, job_ref, response_ref, clean_ref, and
  `suspected_pre_notify_stale`. This annotation is not another rejection.
- `invalid_message`: a fixed phase identifier for malformed JSON, non-object
  messages, invalid ID types/ranges, bad fields or a truncated line at EOF.

No username, password, pool address, agent, extranonce, nonce, raw job ID or
arbitrary pool string is copied to this channel. Jobs use deterministic SHA256
digests for correlation; these are pseudonyms, not anonymization against a
dictionary of known IDs. Error message strings and error data objects are
deliberately omitted. Ordinary console/diagnostic logs are a separate existing
channel and are NOT covered by this sanitization guarantee.

`clean_ref` points to the first observed clean job that invalidated a pending
job. Pre-notify annotations link the already counted rejection and the later
clean event. Neither pre- nor post-notify temporal attribution establishes
pool-side causality. `suspected_post_notify_stale` must never be imported as
confirmed stale. Raw explicit pool evidence would need separate review.

## Response-ID defect found by the new negative test

Previously `get<int>()` could narrow a 64-bit response ID to a live pending ID.
The replay sends `2^32 + pending_id` with success before the real rejection.
Before the range guard, the replay failed: accepted=2, rejected=1 instead of
accepted=1, rejected=2. IDs now must be JSON integers in [0, INT_MAX] before
conversion. Large unsigned, negative, floating-point and string IDs cannot
consume a pending share. The evidence channel reports the invalid message
without copying its value. Valid-response accounting is otherwise unchanged.

## Local validation scope

The bounded Linux replays exercise the real production Client, two TCP
connections, clean transitions, repeated/contradictory responses, unsafe pool
strings, invalid IDs and a throwing evidence sink. Tests write actual JSONL
through the same file helper as the console; Lab's independent auditor checks
the resulting files. The file-helper test checks exact bytes, 0600 permissions,
exclusive creation, symlink refusal and writes after close.

Direct GCC C++20 Release-style builds use -O2 -DNDEBUG, warnings and pthreads.
The original run syntax-checked the CPU and CUDA preprocessor paths without
a full console link. The later direct CPU link and core tests are described
below. No nvcc build, full CMake suite, GPU correctness, performance, hardware
recovery or real-pool behavior is established by these local checks.

Lab's `scripts/analysis/stratum_evidence_audit.py` checks event integrity and
correlation, not admission. Missing events/final records, malformed input,
cross-epoch links and inconsistent counts fail closed. Concurrent disconnect
or shutdown races that produce events outside a connection are reported as
incomplete; the auditor must not invent missing events. One complete file is
required per Client run. This does not repair unrelated socket lifecycle races.

Next: full bounded CPU build/package verification and reviewed conversion of
the diagnostic graph to policy evidence. The existing live gate is unchanged;
no automatic pool launch or confirmed-stale classification is added.

## Recovered and revalidated 2026-10-04

The previously local implementation was recovered without treating the old
STATUS entry as proof that the work was lost. Fresh direct GCC builds and
all six Linux local scenarios passed. Lab's auditor now has 27 mutation
tests; its existing policy evaluator has 21 tests. Four added negative
mutations reproduced false VALID_DIAGNOSTIC classifications before the
auditor fix (unobserved job, out-of-range ID, inconsistent error shape and
non-first pre-notify clean reference).

A complete direct CPU console link and the native core tests passed with
BLAKE3 1.8.5 portable C sources and nlohmann/json 3.11.3. Production objects
use Release flags; the assert-based core-test translation unit uses
`-UNDEBUG`. This checks all five consensus vectors and target boundaries.
Only `--help` and `--version` are executed on the linked console: no pool
client or GPU is started. The console signal pointer is cleared before
evidence finalization can throw during shutdown.

CMake is absent from this execution environment. Consequently CMake/CTest
integration and packaging remain UNTESTED, not PASS. The CMake core-test
target now preserves assertions in Release and has a 30-second timeout;
this configuration change still needs a real CMake run. CUDA syntax-path
checking by the host compiler is not an nvcc build, GPU gate, or artifact
promotion. Source/binary hashes and exact commands are saved with Lab's
bounded local gate results. No speed improvement is claimed.
