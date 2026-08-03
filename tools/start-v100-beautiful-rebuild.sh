#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE="https://raw.githubusercontent.com/iPepew/PepePow_Miner/release/v1.0.0/tools"
RUNNER=/root/build-v100-beautiful-release.sh
PATCHER=/root/prepare-v100-beautiful-source.py
WATCHER=/root/watch-v100-release-build.sh
LOG=/root/v100-beautiful-release-build.log
SCREEN=v100-beautiful-release-build

screen -S "$SCREEN" -X quit 2>/dev/null || true
curl -fsSL "$BASE/build-v100-release.sh" -o "$RUNNER"
curl -fsSL "$BASE/prepare-v100-beautiful-source.py" -o "$PATCHER"
curl -fsSL "$BASE/watch-v100-release-build.sh" -o "$WATCHER"
chmod +x "$RUNNER" "$PATCHER" "$WATCHER"

python3 - "$RUNNER" "$PATCHER" <<'PY'
from pathlib import Path
import sys

runner = Path(sys.argv[1])
patcher = Path(sys.argv[2])
text = runner.read_text(encoding="utf-8")

replacements = [
    (
        'PACKAGE_DIR="$PACKAGE_PARENT/pepepowminer-v1.0.0"',
        'PACKAGE_DIR="$PACKAGE_PARENT/PepeW-Miner-v1.0.0-HiveOS"',
        'package root',
    ),
    (
        'for command_name in bash git cmake ctest python3 sha256sum tar awk sed grep nvidia-smi curl; do',
        'for command_name in bash git cmake ctest python3 sha256sum tar awk sed grep nvidia-smi curl timeout; do',
        'timeout dependency',
    ),
    (
        'STABLE_PACKAGE="$(find_stable_package || true)"\n[[ -n "$STABLE_PACKAGE" ]] || fail "installed PepeW stable package not found"',
        'STABLE_PACKAGE=""',
        'stable package dependency',
    ),
    (
        'git clone --depth 1 --branch "$RELEASE_REF" "$REPO_URL" "$SRC"',
        'git clone --depth 1 --branch "$RELEASE_REF" "$REPO_URL" "$SRC"\npython3 "' + str(patcher) + '" "$SRC"',
        'source patch hook',
    ),
    (
        'mkdir -p "$PACKAGE_DIR"\ncp -a "$STABLE_PACKAGE/." "$PACKAGE_DIR/"\ninstall -m 0755 "$BUILD/pepepowminer" "$PACKAGE_DIR/pepepowminer"',
        '''rm -rf "$PACKAGE_DIR"
mkdir -p "$PACKAGE_DIR"
install -m 0755 "$BUILD/pepepowminer" "$PACKAGE_DIR/pepepowminer"
install -m 0755 "$SRC/hiveos/h-config.sh" "$PACKAGE_DIR/h-config.sh"
install -m 0755 "$SRC/hiveos/h-run.sh" "$PACKAGE_DIR/h-run.sh"
install -m 0755 "$SRC/hiveos/h-stats.sh" "$PACKAGE_DIR/h-stats.sh"
install -m 0755 "$SRC/hiveos/stratum-replay-proxy.py" "$PACKAGE_DIR/stratum-replay-proxy.py"
install -m 0644 "$SRC/hiveos/h-manifest.conf" "$PACKAGE_DIR/h-manifest.conf"''',
        'whitelist package assembly',
    ),
    (
        '''        if m:
            stack,stores,loads=map(int,m.groups())
            break
print(regs or 0, stack or 0, stores or 0, loads or 0)''',
        '''        if m:
            stack,stores,loads=map(int,m.groups())
        if regs is not None and stack is not None and stores is not None and loads is not None:
            break
print(regs or 0, stack or 0, stores or 0, loads or 0)''',
        'ptxas parser',
    ),
    (
        '''        echo "UPLOAD=SHA256"
        "$PUBLISHER" "$SHA_FILE" || true
''',
        '',
        'duplicate checksum upload',
    ),
]

for old, new, label in replacements:
    if old not in text:
        raise SystemExit(f"ERROR: runner patch anchor not found: {label}")
    text = text.replace(old, new, 1)

archive_anchor = 'sha256sum "$ARCHIVE" >"$SHA_FILE"\n'
archive_check = r'''sha256sum "$ARCHIVE" >"$SHA_FILE"

EXPECTED_ROOT="PepeW-Miner-v1.0.0-HiveOS/"
ACTUAL_ROOT="$(tar -tzf "$ARCHIVE" | sed -n '1p')"
[[ "$ACTUAL_ROOT" == "$EXPECTED_ROOT" ]] || \
    fail "invalid HiveOS archive root: $ACTUAL_ROOT"

if tar -tzf "$ARCHIVE" | grep -Eq '(^|/)(config\.txt|setup\.txt|run\.txt|.*\.log(\.previous)?|.*\.pid|miner-status\.env)$'; then
    fail "runtime or wallet artifacts detected in release archive"
fi

MANIFEST_PATH="$PACKAGE_DIR/h-manifest.conf"
grep -qx 'CUSTOM_VERSION=1.0.0' "$MANIFEST_PATH" || fail "HiveOS manifest version mismatch"
grep -qx 'CUSTOM_NAME=PepeW-Miner' "$MANIFEST_PATH" || fail "HiveOS manifest name mismatch"
grep -q 'PepeW-Miner-v1.0.0-HiveOS/config.txt' "$MANIFEST_PATH" || fail "HiveOS manifest path mismatch"
grep -q '"ver":"1.0.0"' "$PACKAGE_DIR/h-stats.sh" || fail "HiveOS stats version missing"
grep -q 'https://t.me/pepepow_ru' "$SRC/native/src/app/main.cpp" || fail "Telegram branding missing"

echo "PACKAGE_ROOT_CHECK=PASS"
echo "PACKAGE_SANITIZED=PASS"
echo "HIVEOS_MANIFEST=PASS"
echo "BRANDING=PASS"
'''
if archive_anchor not in text:
    raise SystemExit("ERROR: archive verification anchor not found")
text = text.replace(archive_anchor, archive_check, 1)

runner.write_text(text, encoding="utf-8")
PY

rm -f "$LOG"
screen -dmS "$SCREEN" bash -lc "$RUNNER 2>&1 | tee $LOG"
sleep 3
REFRESH=5 "$WATCHER" "$LOG"
