#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE_URL="https://raw.githubusercontent.com/iPepew/PepePow_Miner/release/v1.0.1/tools"
ORIGINAL=/root/build-v101-release-original.sh
PATCHED=/root/build-v101-release-patched.sh

curl -fsSL "$BASE_URL/build-v101-release.sh?rev=binary-identity-v8" -o "$ORIGINAL"

python3 - "$ORIGINAL" "$PATCHED" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1])
out = Path(sys.argv[2])
text = src.read_text(encoding="utf-8")
anchor = 'text = text.replace("1.0.0", "1.0.1")\n'
insert = r'''text = text.replace("1.0.0", "1.0.1")

# The escaped version regex in the v1.0.0 base script is not changed by the
# plain string replacement above. Replace the complete generated shell check
# with a fixed-string identity gate for v1.0.1.
binary_identity_old = "grep -q '1\\.0\\.0' <<<\"$BINARY_VERSION\" || fail \"binary identity is not v1.0.1: $BINARY_VERSION\""
binary_identity_new = "grep -Fq 'PepeW Miner v1.0.1 |' <<<\"$BINARY_VERSION\" || fail \"binary identity is not v1.0.1: $BINARY_VERSION\""
if binary_identity_old not in text:
    raise SystemExit("ERROR: v1.0.1 binary identity anchor not found")
text = text.replace(binary_identity_old, binary_identity_new, 1)

# publish-test-results.sh already uploads the archive and its adjacent
# .sha256 file. Passing SHA_FILE to it a second time creates a bogus
# .sha256.sha256 artifact and misleading download URLs.
upload_old = '''        echo "UPLOAD=ARCHIVE"
        "$PUBLISHER" "$ARCHIVE" || true
        echo "UPLOAD=SHA256"
        "$PUBLISHER" "$SHA_FILE" || true'''
upload_new = '''        echo "UPLOAD=ARCHIVE_AND_SHA256"
        "$PUBLISHER" "$ARCHIVE" || true
        echo "UPLOAD_SHA256=HANDLED_BY_PUBLISHER"'''
if upload_old not in text:
    raise SystemExit("ERROR: duplicate SHA256 upload anchor not found")
text = text.replace(upload_old, upload_new, 1)
'''
if anchor not in text:
    raise SystemExit("ERROR: v1.0.1 generator version anchor not found")
text = text.replace(anchor, insert, 1)
out.write_text(text, encoding="utf-8")
PY

chmod +x "$PATCHED"
exec "$PATCHED"
