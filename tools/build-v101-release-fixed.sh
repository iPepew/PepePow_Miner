#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

BASE_URL="https://raw.githubusercontent.com/iPepew/PepePow_Miner/release/v1.0.1/tools"
ORIGINAL=/root/build-v101-release-original.sh
PATCHED=/root/build-v101-release-patched.sh

curl -fsSL "$BASE_URL/build-v101-release.sh?rev=hiveos-flat-v9" -o "$ORIGINAL"

python3 - "$ORIGINAL" "$PATCHED" <<'PY'
from pathlib import Path
import sys

src = Path(sys.argv[1])
out = Path(sys.argv[2])
text = src.read_text(encoding="utf-8")

version_anchor = 'text = text.replace("1.0.0", "1.0.1")\n'
version_insert = """text = text.replace("1.0.0", "1.0.1")

# The escaped version regex in the v1.0.0 base script is not changed by the
# plain string replacement above. Replace the complete generated shell check
# with a fixed-string identity gate for v1.0.1.
binary_identity_old = "grep -q '1\\\\.0\\\\.0' <<<\\\"$BINARY_VERSION\\\" || fail \\\"binary identity is not v1.0.1: $BINARY_VERSION\\\""
binary_identity_new = "grep -Fq 'PepeW Miner v1.0.1 |' <<<\\\"$BINARY_VERSION\\\" || fail \\\"binary identity is not v1.0.1: $BINARY_VERSION\\\""
if binary_identity_old not in text:
    raise SystemExit("ERROR: v1.0.1 binary identity anchor not found")
text = text.replace(binary_identity_old, binary_identity_new, 1)

# HiveOS custom-get extracts the archive into /hive/miners/custom/<Miner name>.
# Store package files at the tar root to avoid a double-nested directory.
tar_pack_old = 'tar -C "$PACKAGE_PARENT" -czf "$ARCHIVE" "$(basename "$PACKAGE_DIR")"'
tar_pack_new = '''tar -C "$PACKAGE_DIR" -czf "$ARCHIVE" \\
    BUILD_PROFILE LICENSE README.md RELEASE_MANIFEST.txt RELEASE_NOTES_v1.0.1.md VERSION \\
    h-config.sh h-manifest.conf h-run.sh h-stats.sh \\
    pepepowminer pepepowminer.sha256 stratum-replay-proxy.py'''
if tar_pack_old not in text:
    raise SystemExit("ERROR: nested HiveOS archive command anchor not found")
text = text.replace(tar_pack_old, tar_pack_new, 1)

# Keep the checksum portable after installation instead of embedding a build-rig path.
binary_sha_old = 'sha256sum "$PACKAGE_DIR/pepepowminer" >"$PACKAGE_DIR/pepepowminer.sha256"'
binary_sha_new = '(cd "$PACKAGE_DIR" && sha256sum pepepowminer >pepepowminer.sha256)'
if binary_sha_old not in text:
    raise SystemExit("ERROR: binary checksum anchor not found")
text = text.replace(binary_sha_old, binary_sha_new, 1)

# publish-test-results.sh already uploads the archive and its adjacent
# .sha256 file. Passing SHA_FILE to it a second time creates .sha256.sha256.
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
"""
if version_anchor not in text:
    raise SystemExit("ERROR: v1.0.1 generator version anchor not found")
text = text.replace(version_anchor, version_insert, 1)

write_anchor = 'out.write_text(text, encoding="utf-8")\n'
write_insert = """# The v1.0.1 generator inserts the archive validation block after the
# version hook above, so normalize that final block immediately before write.
archive_root_old = r'''EXPECTED_ROOT="PepeW-Miner-v1.0.1-HiveOS/"
ACTUAL_ROOT="$(tar -tzf "$ARCHIVE" | sed -n '1p')"
[[ "$ACTUAL_ROOT" == "$EXPECTED_ROOT" ]] || \\
    fail "invalid HiveOS archive root: $ACTUAL_ROOT"'''
archive_root_new = r'''ARCHIVE_LIST="$WORK_ROOT/archive-files.txt"
tar -tzf "$ARCHIVE" >"$ARCHIVE_LIST"
grep -Fqx 'h-manifest.conf' "$ARCHIVE_LIST" || \\
    fail "h-manifest.conf is not at the HiveOS archive root"
if grep -Eq '^[^/]+/h-manifest\\.conf$' "$ARCHIVE_LIST"; then
    fail "nested HiveOS archive directory detected"
fi'''
if archive_root_old not in text:
    raise SystemExit("ERROR: versioned archive root validation anchor not found")
text = text.replace(archive_root_old, archive_root_new, 1)

out.write_text(text, encoding="utf-8")
"""
if write_anchor not in text:
    raise SystemExit("ERROR: generator write anchor not found")
text = text.replace(write_anchor, write_insert, 1)

out.write_text(text, encoding="utf-8")
PY

chmod +x "$PATCHED"
exec "$PATCHED"
