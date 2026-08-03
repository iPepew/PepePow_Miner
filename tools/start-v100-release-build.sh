#!/usr/bin/env bash
set -euo pipefail
BASE="https://raw.githubusercontent.com/iPepew/PepePow_Miner/release/v1.0.0/tools"
RUNNER=/root/build-v100-release.sh
WATCHER=/root/watch-v100-release-build.sh
LOG=/root/v100-release-build.log
SCREEN=v100-release-build

screen -S "$SCREEN" -X quit 2>/dev/null || true
curl -fsSL "$BASE/build-v100-release.sh" -o "$RUNNER"
curl -fsSL "$BASE/watch-v100-release-build.sh" -o "$WATCHER"

# Apply release-runner corrections before launch. The source branch remains
# immutable during the build; these edits only harden the downloaded runner.
python3 - "$RUNNER" <<'PY'
from pathlib import Path
import sys
path=Path(sys.argv[1])
text=path.read_text(encoding='utf-8')
text=text.replace(
    'for command_name in bash git cmake ctest python3 sha256sum tar awk sed grep nvidia-smi curl; do',
    'for command_name in bash git cmake ctest python3 sha256sum tar awk sed grep nvidia-smi curl timeout; do')
text=text.replace(
'''        if m:
            stack,stores,loads=map(int,m.groups())
            break
print(regs or 0, stack or 0, stores or 0, loads or 0)''',
'''        if m:
            stack,stores,loads=map(int,m.groups())
        if regs is not None and stack is not None and stores is not None and loads is not None:
            break
print(regs or 0, stack or 0, stores or 0, loads or 0)''')
text=text.replace(
'''        echo "UPLOAD=SHA256"
        "$PUBLISHER" "$SHA_FILE" || true
''','')
path.write_text(text, encoding='utf-8')
PY

chmod +x "$RUNNER" "$WATCHER"
rm -f "$LOG"
screen -dmS "$SCREEN" bash -lc "$RUNNER 2>&1 | tee $LOG"
sleep 3
REFRESH=5 "$WATCHER" "$LOG"
