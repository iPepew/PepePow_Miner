#!/usr/bin/env bash
set -euo pipefail
umask 077

# The original v0.7.1 matrix body is pinned so this launcher is reproducible.
# Patch the Bash nounset bug before execution: variables derived from `profile`
# must not be expanded in the same `local` statement that initializes it.
PINNED_COMMIT="ffad779eac872a06ca7d06557a36a47fc559503f"
RAW_URL="https://raw.githubusercontent.com/iPepew/PepePow_Miner/${PINNED_COMMIT}/tools/run-v071-safe-zero-matrix.sh"
TMP_SCRIPT="$(mktemp /tmp/run-v071-safe-zero-matrix.XXXXXX.sh)"

cleanup() {
  rm -f "${TMP_SCRIPT}"
}
trap cleanup EXIT

curl -fsSL "${RAW_URL}" -o "${TMP_SCRIPT}"

python3 - "${TMP_SCRIPT}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = '''run_profile(){
  local profile="$1" dir="$BUILD_ROOT/$profile" out="$STAGE/profiles/$profile" blog="$STAGE/profiles/$profile/build.log"
  mkdir -p "$out"; rm -rf "$dir"'''
new = '''run_profile(){
  local profile dir out blog
  profile="${1:?missing profile name}"
  dir="$BUILD_ROOT/$profile"
  out="$STAGE/profiles/$profile"
  blog="$out/build.log"
  mkdir -p "$out"; rm -rf "$dir"'''
if text.count(old) != 1:
    raise SystemExit(f"ERROR: expected one run_profile declaration, found {text.count(old)}")
path.write_text(text.replace(old, new, 1), encoding="utf-8")
PY

chmod +x "${TMP_SCRIPT}"
trap - EXIT
exec bash "${TMP_SCRIPT}" "$@"
