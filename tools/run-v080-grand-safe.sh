#!/usr/bin/env bash
set -euo pipefail

PINNED_RUNNER_COMMIT="57912a9e20d4618c9882fcae02669c817e893c05"
RAW_URL="https://raw.githubusercontent.com/iPepew/PepePow_Miner/${PINNED_RUNNER_COMMIT}/tools/run-v080-grand-campaign.sh"
TMP_SCRIPT="$(mktemp /tmp/run-v080-grand.XXXXXX.sh)"
cleanup(){ rm -f "${TMP_SCRIPT}"; }
trap cleanup EXIT

curl -fsSL "${RAW_URL}" -o "${TMP_SCRIPT}"
python3 - "${TMP_SCRIPT}" <<'PY'
from pathlib import Path
import sys
p=Path(sys.argv[1])
t=p.read_text(encoding='utf-8')
old='''    echo "STATUS=STRESS_TESTING PROFILE=${best_profile} RUNS=${STRESS_RUNS}"
    STRESS_GATE="PASS"
    : >"${STAGE}/stress/benchmark.log"
    for ((run=1; run<=STRESS_RUNS; run++)); do'''
new='''    echo "STATUS=STRESS_TESTING PROFILE=${best_profile} RUNS=${STRESS_RUNS}"
    STRESS_GATE="PASS"
    xid_count_before="$(dmesg 2>/dev/null | grep -Ec 'NVRM: Xid|Xid \\(' || true)"
    : >"${STAGE}/stress/benchmark.log"
    for ((run=1; run<=STRESS_RUNS; run++)); do'''
old2='''    if dmesg 2>/dev/null | tail -n 300 | grep -Eq 'NVRM: Xid|Xid \\('; then
      STRESS_GATE="FAILED_XID"
    fi'''
new2='''    xid_count_after="$(dmesg 2>/dev/null | grep -Ec 'NVRM: Xid|Xid \\(' || true)"
    if (( xid_count_after > xid_count_before )); then
      STRESS_GATE="FAILED_NEW_XID"
    fi'''
if t.count(old)!=1:
    raise SystemExit(f'ERROR: stress-start block count={t.count(old)}')
if t.count(old2)!=1:
    raise SystemExit(f'ERROR: Xid block count={t.count(old2)}')
t=t.replace(old,new,1).replace(old2,new2,1)
p.write_text(t,encoding='utf-8')
PY
chmod +x "${TMP_SCRIPT}"
trap - EXIT
exec bash "${TMP_SCRIPT}" "$@"
