#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="https://raw.githubusercontent.com/iPepew/PepePow_Miner/release/v1.0.0/tools"
RUNNER=/root/build-v100-release.sh
CLEANER=/root/clean-v100-release-package.sh
WATCHER=/root/watch-v100-release-build.sh
WRAPPER=/root/run-v100-release-final.sh
LOG=/root/v100-release-build.log
SCREEN=v100-release-build
ARCHIVE=/root/pepepow-tests/PepeW-Miner-v1.0.0-HiveOS-sm86.tar.gz
STATUS=/root/pepew-v1-release/status.env

screen -S "$SCREEN" -X quit 2>/dev/null || true
curl -fsSL "$BASE/build-v100-release.sh" -o "$RUNNER"
curl -fsSL "$BASE/clean-v100-release-package.sh" -o "$CLEANER"
curl -fsSL "$BASE/watch-v100-release-build.sh" -o "$WATCHER"

# Apply the two compiler-log parser corrections discovered during the release
# rehearsal. The exact consensus-tested CUDA source remains unchanged.
python3 - "$RUNNER" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
text = path.read_text(encoding='utf-8')
text = text.replace(
    'for command_name in bash git cmake ctest python3 sha256sum tar awk sed grep nvidia-smi curl; do',
    'for command_name in bash git cmake ctest python3 sha256sum tar awk sed grep nvidia-smi curl timeout; do')
text = text.replace(
'''        if m:
            stack,stores,loads=map(int,m.groups())
            break
print(regs or 0, stack or 0, stores or 0, loads or 0)''',
'''        if m:
            stack,stores,loads=map(int,m.groups())
        if regs is not None and stack is not None and stores is not None and loads is not None:
            break
print(regs or 0, stack or 0, stores or 0, loads or 0)''')
path.write_text(text, encoding='utf-8')
PY

cat >"$WRAPPER" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

PUBLIC_UPLOAD=0 "$RUNNER" 2>&1 | tee "$LOG"
runner_rc=\${PIPESTATUS[0]}
(( runner_rc == 0 )) || exit "\$runner_rc"

printf 'STATE=RUNNING\nSTEP=sanitize\nDETAIL=release_package\nUPDATED_AT=%q\n' \
  "\$(date --iso-8601=seconds)" >"$STATUS"
"$CLEANER" "$ARCHIVE" 2>&1 | tee -a "$LOG"
clean_rc=\${PIPESTATUS[0]}
if (( clean_rc != 0 )); then
  printf 'STATE=FAILED\nSTEP=sanitize\nDETAIL=package_rejected\nUPDATED_AT=%q\n' \
    "\$(date --iso-8601=seconds)" >"$STATUS"
  exit "\$clean_rc"
fi

if [[ "\${PUBLIC_UPLOAD:-1}" == 1 ]]; then
  publisher=/root/publish-pepepow-test-results.sh
  curl -fsSL \
    https://raw.githubusercontent.com/iPepew/PepePow_Miner/experiment/v2.0.0-warp-service/tools/publish-test-results.sh \
    -o "\$publisher"
  chmod +x "\$publisher"
  "\$publisher" "$ARCHIVE" 2>&1 | tee -a "$LOG" || true
fi

printf 'STATE=COMPLETE\nSTEP=release_gate\nDETAIL=PASS_CLEAN_PACKAGE\nUPDATED_AT=%q\n' \
  "\$(date --iso-8601=seconds)" >"$STATUS"
echo 'FINAL_RELEASE_GATE=PASS' | tee -a "$LOG"
echo 'PACKAGE_SANITIZED=PASS' | tee -a "$LOG"
echo 'RUNTIME_ARTIFACTS=0' | tee -a "$LOG"
echo 'WALLET_DATA=0' | tee -a "$LOG"
EOF

chmod +x "$RUNNER" "$CLEANER" "$WATCHER" "$WRAPPER"
rm -f "$LOG"
screen -dmS "$SCREEN" bash -lc "$WRAPPER"
sleep 3
REFRESH=5 "$WATCHER" "$LOG"
