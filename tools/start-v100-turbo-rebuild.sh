#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="https://raw.githubusercontent.com/iPepew/PepePow_Miner/release/v1.0.0/tools"
BASE_LAUNCHER=/root/start-v100-turbo-base.sh

curl -fsSL "$BASE/start-v100-beautiful-rebuild.sh" -o "$BASE_LAUNCHER"
python3 - "$BASE_LAUNCHER" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")

pairs = [
    (
        'RUNNER=/root/build-v100-beautiful-release.sh',
        'RUNNER=/root/build-v100-turbo-release.sh',
    ),
    (
        'PATCHER=/root/prepare-v100-beautiful-source.py',
        'PATCHER=/root/prepare-v100-turbo-source.py\nBEAUTIFUL=/root/prepare-v100-beautiful-source.py',
    ),
    (
        'LOG=/root/v100-beautiful-release-build.log',
        'LOG=/root/v100-turbo-release-build.log',
    ),
    (
        'SCREEN=v100-beautiful-release-build',
        'SCREEN=v100-turbo-release-build',
    ),
    (
        'curl -fsSL "$BASE/prepare-v100-beautiful-source.py" -o "$PATCHER"',
        'curl -fsSL "$BASE/prepare-v100-turbo-source.py" -o "$PATCHER"\ncurl -fsSL "$BASE/prepare-v100-beautiful-source.py" -o "$BEAUTIFUL"',
    ),
    (
        'chmod +x "$RUNNER" "$PATCHER" "$WATCHER"',
        'chmod +x "$RUNNER" "$PATCHER" "$BEAUTIFUL" "$WATCHER"',
    ),
    (
        'python3 - "$RUNNER" "$PATCHER" <<\'PY\'',
        'python3 - "$RUNNER" "$PATCHER" "$BEAUTIFUL" <<\'PY\'',
    ),
    (
        'patcher = Path(sys.argv[2])',
        'patcher = Path(sys.argv[2])\nbeautiful = Path(sys.argv[3])',
    ),
    (
        "'git clone --depth 1 --branch \"$RELEASE_REF\" \"$REPO_URL\" \"$SRC\"\\npython3 \"' + str(patcher) + '\" \"$SRC\"'",
        "'git clone --depth 1 --branch \"$RELEASE_REF\" \"$REPO_URL\" \"$SRC\"\\npython3 \"' + str(patcher) + '\" \"' + str(beautiful) + '\" \"$SRC\"'",
    ),
]

for old, new in pairs:
    if old not in text:
        raise SystemExit(f"ERROR: turbo launcher anchor not found: {old[:80]}")
    text = text.replace(old, new, 1)

path.write_text(text, encoding="utf-8")
PY

chmod +x "$BASE_LAUNCHER"
exec "$BASE_LAUNCHER"
