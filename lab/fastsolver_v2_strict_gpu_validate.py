#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: fastsolver_v2_strict_gpu_validate.py <generated-cu>")

p = Path(sys.argv[1])
s = p.read_text()
old = '''    // Never submit the approximate GPU result directly. Recompute the rare
    // candidate with the canonical strict CPU HooHash and validate the target.
    const Header80 strict_header=make_header(job,result.nonce);
    const Hash256 strict_hash=crypto::calculate_header80_pow(strict_header);
    if(!mining::hash_meets_target_be(strict_hash,target))return std::nullopt;
    return ShareCandidate{job.job_id,result.nonce,strict_hash};
'''
new = '''    // Never submit the approximate FastSolver result directly. The CPU
    // reference currently does not reproduce the PEPEW HooHashV110 consensus
    // vector (startup KAT reports CPU FAIL / strict GPU PASS), so validate each
    // rare candidate with the strict CUDA hash_one path used by diagnose().
    // This is intentionally outside the hot scan loop and is negligible at
    // share-candidate frequency.
    const Header80CudaDiagnostics strict_diag=diagnose(job,result.nonce);
    const Hash256 strict_hash=strict_diag.final_hash;
    if(!mining::hash_meets_target_be(strict_hash,target))return std::nullopt;
    return ShareCandidate{job.job_id,result.nonce,strict_hash};
'''
if old not in s:
    raise SystemExit("strict CPU validation marker not found")
s = s.replace(old, new, 1)
p.write_text(s)
print("Replaced CPU candidate validation with strict consensus GPU validation")
