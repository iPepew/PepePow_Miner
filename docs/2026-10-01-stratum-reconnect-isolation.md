# Reconnect must end pre-notify attribution history

Base: `a833f74b400ab274f5b05697eef3643615cb1978` on
`agent/demand-sliced-batch-correctness-20260917`.

## Defect and scope

`recent_unspecified_rejects_` survived `clear_pending("connection reset")`.
If a new connection delivered a clean job within the two-second attribution
window, `attribute_pre_notify_stale` could attribute a null-error rejection
from the previous connection to that new job. This is a false temporal
attribution; it does not remove the rejection from the inclusive total.

Clear the receive-thread-owned deque at connection reset, alongside pending
submits. Preserve all session-wide counters. No CUDA, share generation,
admission policy, pool credentials, release or stable/live changes.

## Reproduction and validation (local CPU/loopback only)

The new `stratum_reconnect_replay.cpp` uses the production Client and two
loopback TCP connections, synthetic credentials, and bounded socket waits.
It sends a null-error rejection in the first connection, reconnects inside
two seconds, then delivers a clean job, a duplicate old response, an explicit
low-difficulty rejection beside another clean job, and an accepted share.
Job callbacks provide receive-order barriers; the test does not poll stats.
The test checks timing so an excessively slow reconnect cannot mask the bug.

- Before fix: accepted=1, rejected=2, clean_job_stale=1, reconnects=1;
  exit 1 with `old-connection rejection leaked into new clean job`.
- After fix: accepted=1, rejected=2, clean_job_stale=0, reconnects=1;
  PASS. Duplicate response is ignored and explicit rejection preserved.
- Existing `stratum_clean_job_replay.cpp`: accepted=2, rejected=3,
  clean_job_stale=2; PASS. Same-connection temporal attribution is retained.

Both were compiled directly with GCC 13.3.0, C++20, `-O2 -DNDEBUG`, warnings,
and pthreads, using the project's pinned nlohmann/json v3.11.3. The header's
Git blob is `8b72ea6539f40e4e3f7762d17e30c67f2a8308ed`. Compile timeouts were
60/45 seconds; each test had a 15-second process timeout. No external pool,
GPU, hosted workflow or hardware session was started. Tests do not rely on
assertions being enabled. CMake registers the new replay with TIMEOUT=15;
the full CMake/core suite was not run in this session.

Direct local build (set JSON_INCLUDE to the directory containing nlohmann/):

```sh
timeout -k 2s 60s g++ -std=c++20 -O2 -DNDEBUG -Wall -Wextra -Wpedantic \
  -Wconversion -pthread -I"$JSON_INCLUDE" -Inative/include \
  native/src/network/stratum_client.cpp native/tests/stratum_reconnect_replay.cpp \
  -o /tmp/pepepow_stratum_reconnect_replay
timeout -k 1s 15s /tmp/pepepow_stratum_reconnect_replay
```

## Remaining work

This does not establish the cause of historical real-pool rejects and does
not convert temporal attribution into confirmed stale. The structured
Stratum journal (monotonic time, connection epoch, submit/response identity,
sanitized result/error and clean invalidation references), its raw-log
adapter, further negative socket cases and reviewed evidence remain needed.
No new performance measurement or pool admission is claimed.
