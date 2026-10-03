# Same-connection duplicate and contradictory responses

Extended the bounded reconnect socket replay on base
`53cac1370068032fe256457c66937fbba5e92f01` with four responses for completed
IDs in the current connection: duplicate rejection, contradictory success,
duplicate success and contradictory rejection. The existing receive-order
barrier ensures all responses are consumed before counters are checked.

Local result on 2026-10-03: PASS, accepted=1, rejected inclusive=2,
clean_job_stale=0, reconnects=1, reject_to_clean_ms=0. Production source is
unchanged (SHA256 `102d955ee29689871548e911e54247eb6ba31211ba9195a4a49db15e1d695459`).
The extended test was compiled with GCC, C++20, -O2 -DNDEBUG and warnings,
linked against the previously built production object (SHA256
`556b2ed7feacf047fa26bb818702d81a2c172c675ee30ca714048a0b4ab13495`).
Compile timeout 60 seconds, loopback process timeout 15 seconds with a
1-second kill grace. Initial sandbox execution could not create a socket;
the approved local loopback retry passed. No external service was contacted.

This is one extended local socket test, not a fresh full production build,
full CMake suite, CUDA gate or performance measurement. No pool, GPU or
hosted workflow was launched. No admission, stable/live or production code
changed. Structured evidence logging and its adapter remain outstanding.
