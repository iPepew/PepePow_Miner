#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

ARCHIVE="${1:?usage: clean-v100-release-package.sh ARCHIVE.tar.gz}"
[[ -f "$ARCHIVE" ]] || { echo "ERROR: archive not found: $ARCHIVE" >&2; exit 1; }
ARCHIVE="$(readlink -f "$ARCHIVE")"
SHA_FILE="${ARCHIVE}.sha256"
TMP_ROOT="$(mktemp -d /tmp/pepew-v100-clean.XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT
PKG="$TMP_ROOT/pepepowminer-v1.0.0"
mkdir -p "$PKG"

mapfile -t ALL_NAMES < <(tar -tzf "$ARCHIVE")
((${#ALL_NAMES[@]} > 0)) || { echo "ERROR: empty archive" >&2; exit 1; }
for name in "${ALL_NAMES[@]}"; do
  [[ "$name" != /* && "$name" != *../* && "$name" != ../* ]] || {
    echo "ERROR: unsafe archive path: $name" >&2; exit 1;
  }
done
ROOT="${ALL_NAMES[0]%%/*}"
[[ -n "$ROOT" ]] || { echo "ERROR: package root not found" >&2; exit 1; }

FILES=(
  pepepowminer VERSION BUILD_PROFILE RELEASE_MANIFEST.txt README.md
  RELEASE_NOTES_v1.0.0.md LICENSE h-config.sh h-run.sh h-stats.sh
  h-manifest.conf stratum-replay-proxy.py
)
for file in "${FILES[@]}"; do
  member="$ROOT/$file"
  tar -tzf "$ARCHIVE" "$member" >/dev/null 2>&1 || {
    echo "ERROR: missing required file: $file" >&2; exit 1;
  }
  tar -xOf "$ARCHIVE" "$member" >"$PKG/$file"
done

[[ "$(tr -d '[:space:]' <"$PKG/VERSION")" == 1.0.0 ]] || {
  echo "ERROR: VERSION is not 1.0.0" >&2; exit 1;
}
chmod 0755 "$PKG/pepepowminer"
BINARY_VERSION="$("$PKG/pepepowminer" --version 2>&1 || true)"
grep -q '1\.0\.0' <<<"$BINARY_VERSION" || {
  echo "ERROR: binary identity is not v1.0.0: $BINARY_VERSION" >&2; exit 1;
}
BINARY_SHA="$(sha256sum "$PKG/pepepowminer" | awk '{print $1}')"
MANIFEST_SHA="$(sed -n 's/^binary_sha256=//p' "$PKG/RELEASE_MANIFEST.txt" | tail -n1)"
[[ "$BINARY_SHA" == "$MANIFEST_SHA" ]] || {
  echo "ERROR: binary SHA mismatch" >&2; exit 1;
}

cat >"$PKG/h-manifest.conf" <<'EOF'
CUSTOM_NAME=pepepowminer
CUSTOM_VERSION=1.0.0
MINER_NAME=$CUSTOM_NAME
MINER_VERSION=$CUSTOM_VERSION
CUSTOM_CONFIG_FILENAME=/hive/miners/custom/pepepowminer-v1.0.0/config.txt
MINER_CONFIG_FILENAME=$CUSTOM_CONFIG_FILENAME
CUSTOM_LOG_BASENAME=/var/log/miner/custom/$CUSTOM_NAME
MINER_API_PORT=4049
EOF

python3 - "$PKG/h-config.sh" "$PKG/h-run.sh" <<'PY'
from pathlib import Path
import re, sys
config, run = map(Path, sys.argv[1:3])

def add_umask(text):
    if 'umask 077' in text:
        return text
    lines = text.splitlines()
    lines.insert(1 if lines and lines[0].startswith('#!') else 0, 'umask 077')
    return '\n'.join(lines) + '\n'

text = add_umask(config.read_text())
pattern = re.compile(r'\{\n  echo "Miner directory: \$\{miner_dir\}".*?\n\} > "\$\{setup_file\}"', re.S)
replacement = '''{
  echo "Miner directory: ${miner_dir}"
  echo "Upstream pool: configured via HiveOS"
  echo "Local proxy: stratum+tcp://127.0.0.1:${proxy_port}"
  echo "User: configured via HiveOS"
  echo "Password: configured via HiveOS"
  echo "Extra config: ${extra_raw:+configured}"
  echo "Compatibility --pepepow injection: disabled"
  echo "Proxy submit rewriting: disabled"
  echo "Pool reference: matrix_seed=BLAKE3(masked_header), header_nonce=BE32, mix_nonce=LE32, submit_nonce=LE_HEX"
  echo "Diagnostic mode: enabled"
  echo "Diagnostic log: ${diagnostic_log}"
  echo "Proxy log: ${proxy_log}"
  echo "Final miner command: ./pepepowminer [credentials supplied by HiveOS]"
} > "${setup_file}"
chmod 600 "${conf_file}" "${setup_file}"'''
text, count = pattern.subn(replacement, text, count=1)
if count != 1:
    raise SystemExit('ERROR: h-config privacy patch failed')
config.write_text(text)

text = add_umask(run.read_text())
text, count = re.subn(
    r'  echo "== ENVIRONMENT =="\n  env \| sort',
    '  echo "== SAFE ENVIRONMENT =="\n  echo "PATH=${PATH:-}"\n  echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}"',
    text,
    count=1,
)
if count != 1:
    raise SystemExit('ERROR: h-run environment patch failed')
text, count = re.subn(
    r"  printf './pepepowminer'\n  printf ' %q' \"\$\{PEPEPOW_ARGS\[@\]\}\"\n  echo",
    '  echo "./pepepowminer [arguments supplied by HiveOS]"',
    text,
    count=1,
)
if count != 1:
    raise SystemExit('ERROR: h-run command patch failed')
run.write_text(text)
PY

sed -i '/^package_sanitized=/d;/^runtime_artifacts_included=/d;/^wallet_data_included=/d' "$PKG/RELEASE_MANIFEST.txt"
cat >>"$PKG/RELEASE_MANIFEST.txt" <<'EOF'
package_sanitized=PASS
runtime_artifacts_included=0
wallet_data_included=0
EOF
printf '%s  pepepowminer\n' "$BINARY_SHA" >"$PKG/pepepowminer.sha256"

chmod 0755 "$PKG" "$PKG/pepepowminer" "$PKG/h-config.sh" "$PKG/h-run.sh" \
  "$PKG/h-stats.sh" "$PKG/stratum-replay-proxy.py"
chmod 0644 "$PKG/VERSION" "$PKG/BUILD_PROFILE" "$PKG/RELEASE_MANIFEST.txt" \
  "$PKG/README.md" "$PKG/RELEASE_NOTES_v1.0.0.md" "$PKG/LICENSE" \
  "$PKG/h-manifest.conf" "$PKG/pepepowminer.sha256"
for script in h-config.sh h-run.sh h-stats.sh; do
  bash -n "$PKG/$script"
done

if grep -RIEq --exclude=pepepowminer '\bP[1-9A-HJ-NP-Za-km-z]{25,50}(\.[A-Za-z0-9_.-]+)?\b' "$PKG"; then
  echo "ERROR: wallet-like data remains in release package" >&2
  exit 1
fi
if grep -RIFq --exclude=pepepowminer '0.6.0-PR' "$PKG"; then
  echo "ERROR: old v0.6.0-PR identity remains" >&2
  exit 1
fi

TMP_ARCHIVE="${ARCHIVE}.clean.tmp"
MTIME="$(stat -c %Y "$PKG/pepepowminer")"
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$MTIME" \
  -C "$TMP_ROOT" -czf "$TMP_ARCHIVE" pepepowminer-v1.0.0
mv -f "$TMP_ARCHIVE" "$ARCHIVE"
ARCHIVE_SHA="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
printf '%s  %s\n' "$ARCHIVE_SHA" "$(basename "$ARCHIVE")" >"$SHA_FILE"

echo "RELEASE_SANITIZE=PASS"
echo "ARCHIVE=$ARCHIVE"
echo "ARCHIVE_SHA256=$ARCHIVE_SHA"
echo "SHA256_FILE=$SHA_FILE"
echo "RUNTIME_ARTIFACTS=0"
echo "WALLET_DATA=0"
