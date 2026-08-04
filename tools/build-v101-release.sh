#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE_URL="https://raw.githubusercontent.com/iPepew/PepePow_Miner/release/v1.0.1/tools"
BASE_RUNNER=/root/build-v101-base.sh
GENERATED_RUNNER=/root/build-v101-generated.sh
PATCHER=/root/prepare-v101-source.py

curl -fsSL "$BASE_URL/build-v100-release.sh" -o "$BASE_RUNNER"
curl -fsSL "$BASE_URL/prepare-v101-source.py" -o "$PATCHER"
chmod +x "$BASE_RUNNER" "$PATCHER"

python3 - "$BASE_RUNNER" "$GENERATED_RUNNER" "$PATCHER" <<'PY'
from pathlib import Path
import sys

base = Path(sys.argv[1])
out = Path(sys.argv[2])
patcher = Path(sys.argv[3])
text = base.read_text(encoding="utf-8")

replacements = [
    (
        'WORK_ROOT="${WORK_ROOT:-/root/pepew-v1-release}"',
        'WORK_ROOT="${WORK_ROOT:-/root/pepew-v101-release}"',
        'work root',
    ),
    (
        'PACKAGE_DIR="$PACKAGE_PARENT/pepepowminer-v1.0.0"',
        'PACKAGE_DIR="$PACKAGE_PARENT/PepeW-Miner-v1.0.1-HiveOS"',
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
        'source preparation hook',
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
        'ptxas resource parser',
    ),
]

for old, new, label in replacements:
    if old not in text:
        raise SystemExit(f"ERROR: v1.0.1 builder anchor not found: {label}")
    text = text.replace(old, new, 1)

text = text.replace("v1.0.0", "v1.0.1")
text = text.replace("1.0.0", "1.0.1")

package_test_anchor = 'rm -f "$ARCHIVE" "$SHA_FILE"\n'
package_test = r'''echo "RELEASE_STAGE=HIVEOS_TELEMETRY_SELFTEST"
bash -n "$PACKAGE_DIR/h-config.sh"
bash -n "$PACKAGE_DIR/h-run.sh"
bash -n "$PACKAGE_DIR/h-stats.sh"

grep -Fqx 'CUSTOM_NAME=PepeW-Miner' "$PACKAGE_DIR/h-manifest.conf" || \
    fail "HiveOS manifest name mismatch"
grep -Fqx 'CUSTOM_VERSION=1.0.1' "$PACKAGE_DIR/h-manifest.conf" || \
    fail "HiveOS manifest version mismatch"
grep -Fq 'PepeW-Miner-v1.0.1-HiveOS/config.txt' "$PACKAGE_DIR/h-manifest.conf" || \
    fail "HiveOS manifest config path mismatch"
grep -Fq -- '--diagnostic-log' "$PACKAGE_DIR/h-config.sh" || \
    fail "h-config.sh does not pin miner-status.env to package directory"
grep -Fq '"khs":%s' "$PACKAGE_DIR/h-stats.sh" || \
    fail "h-stats.sh does not emit native HiveOS khs schema"

TELEMETRY_FIXTURE="$WORK_ROOT/telemetry-selftest.env"
cat >"$TELEMETRY_FIXTURE" <<TELEMETRY
HPS=2137000
ACCEPTED=42
REJECTED=0
UPTIME=60
UPDATED_EPOCH=$(date +%s)
PID=0
GPU_COUNT=1
STATE=mining
TELEMETRY

TELEMETRY_OUTPUT="$(PEPEW_STATUS_FILE="$TELEMETRY_FIXTURE" PEPEW_STATS_SELFTEST=1 \
    bash -c 'set -u; source "$1"; printf "%s\n%s\n" "$khs" "$stats"' \
    _ "$PACKAGE_DIR/h-stats.sh")"
TELEMETRY_KHS="$(sed -n '1p' <<<"$TELEMETRY_OUTPUT")"
TELEMETRY_JSON="$(sed -n '2p' <<<"$TELEMETRY_OUTPUT")"
[[ "$TELEMETRY_KHS" == "2137" ]] || \
    fail "HiveOS total khs self-test failed: $TELEMETRY_KHS"
grep -Fq '"khs":[2137]' <<<"$TELEMETRY_JSON" || \
    fail "HiveOS per-GPU khs self-test failed: $TELEMETRY_JSON"
grep -Fq '"ver":"1.0.1"' <<<"$TELEMETRY_JSON" || \
    fail "HiveOS version self-test failed: $TELEMETRY_JSON"
grep -Fq '"algo":"hoohash"' <<<"$TELEMETRY_JSON" || \
    fail "HiveOS algorithm self-test failed: $TELEMETRY_JSON"
echo "HIVEOS_TELEMETRY_GATE=PASS total_khs=$TELEMETRY_KHS stats=$TELEMETRY_JSON"

rm -f "$ARCHIVE" "$SHA_FILE"
'''
if package_test_anchor not in text:
    raise SystemExit("ERROR: package test anchor not found")
text = text.replace(package_test_anchor, package_test, 1)

archive_anchor = 'sha256sum "$ARCHIVE" >"$SHA_FILE"\n'
archive_check = r'''sha256sum "$ARCHIVE" >"$SHA_FILE"

EXPECTED_ROOT="PepeW-Miner-v1.0.1-HiveOS/"
ACTUAL_ROOT="$(tar -tzf "$ARCHIVE" | sed -n '1p')"
[[ "$ACTUAL_ROOT" == "$EXPECTED_ROOT" ]] || \
    fail "invalid HiveOS archive root: $ACTUAL_ROOT"

if tar -tzf "$ARCHIVE" | grep -Eq '(^|/)(config\.txt|setup\.txt|run\.txt|.*\.log(\.previous)?|.*\.pid|miner-status\.env)$'; then
    fail "runtime, wallet or generated configuration artifacts detected"
fi

echo "PACKAGE_ROOT_CHECK=PASS"
echo "PACKAGE_SANITIZED=PASS"
echo "HIVEOS_MANIFEST=PASS"
echo "HIVEOS_TELEMETRY_GATE=PASS"
'''
if archive_anchor not in text:
    raise SystemExit("ERROR: archive validation anchor not found")
text = text.replace(archive_anchor, archive_check, 1)

out.write_text(text, encoding="utf-8")
PY

chmod +x "$GENERATED_RUNNER"
exec "$GENERATED_RUNNER"
