# FP64 audit-harness independence preflight — 2026-09-13

Candidate under review: iPepew/PepePow_Miner@3a809090846f410aceb7fe2b8249fdd8af80a0a5.
Scope: static inspection of an existing LOCAL UNTRACKED draft, tools/audit_trig_slowpath_final.py. This report does not claim that this draft was published, run previously, or used by hosted 34724243309.
Draft SHA256: 6d46a028c52a640d5b80be24114cd026c26c29d37554ea92a2df34367f854974.

## Findings

1. reference_reduce and candidate_reduce both return reconstruct(raw, high, low). Thus independent full-integer-product vs carry-chain inputs do NOT independently validate the downstream FP64 reconstruction.
2. check calls polynomial(*reference); candidate_final also calls the same polynomial helper. This can check quadrant remapping/nested fast reduction but not independently establish polynomial operation order against compiled candidate code.
3. Random loop uses exponent = 31 + i % 26 and sign = i & 1. Because 26 is even, each exponent receives only one sign: 26/52 exponent-sign pairs. All 312 edge vectors cover both signs, but do not close random-interior coverage.
4. No candidate correctness failure is inferred from these harness limitations. No previous hosted PASS is revoked by this preflight.

## Reproduction (CPU only)

Coverage calculation, performed once under timeout 10s:
```python
coverage = {(31 + i % 26, i & 1) for i in range(1_000_000)}
assert len(coverage) == 26
missing = [(e, s) for e in range(31, 57) for s in (0, 1)
           if (e, s) not in coverage]
assert len(missing) == 26
```

AST direct-call inspection of the draft:
- reference_reduce: enumerate, reconstruct, sum
- candidate_reduce: reconstruct
- check: polynomial (reference)
- candidate_final: polynomial (candidate)

Required next implementation: independently replay captured PTX reconstruction and polynomial operations without sharing reconstruct/polynomial with the candidate model; cover all 52 exponent-sign classes (e.g. sign = (i // 26) & 1), plus boundaries. Compiled GPU differential remains a separate mandatory gate.

Result: correctness gate NOT_ESTABLISHED. No CUDA, workflow, performance, pool, miner stop, or live/stable code change was performed. Existing dirty files were preserved. One bounded preflight step completed; pause.
