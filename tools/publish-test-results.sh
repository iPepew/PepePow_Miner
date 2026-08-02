#!/usr/bin/env bash
set -euo pipefail
umask 077

ARCHIVE="${1:-}"
PORT="${DOWNLOAD_PORT:-8081}"
PUBLIC_UPLOAD="${PUBLIC_UPLOAD:-1}"
EXPIRY_HOURS="${EXPIRY_HOURS:-24}"

if [[ -z "${ARCHIVE}" || ! -f "${ARCHIVE}" ]]; then
  echo "DOWNLOAD_STATUS=FAILED"
  echo "DOWNLOAD_ERROR=archive_not_found"
  exit 1
fi

SHA_FILE="${ARCHIVE}.sha256"
if [[ ! -f "${SHA_FILE}" ]]; then
  sha256sum "${ARCHIVE}" > "${SHA_FILE}"
fi

OUT_DIR="$(dirname "${ARCHIVE}")"
ARCHIVE_NAME="$(basename "${ARCHIVE}")"
SHA_NAME="$(basename "${SHA_FILE}")"
LINKS_FILE="${ARCHIVE}.links.txt"
SERVER_LOG="${OUT_DIR}/download-server-${PORT}.log"

pick_port() {
  local candidate
  for candidate in "${PORT}" 8082 8083 8084 8085 8086 8087 8088 8089 8090; do
    if ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "(^|:)${candidate}$"; then
      printf '%s\n' "${candidate}"
      return 0
    fi
    if pgrep -af "python3 -m http.server ${candidate} .*--directory ${OUT_DIR}" >/dev/null 2>&1; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  return 1
}

PORT="$(pick_port || true)"
if [[ -n "${PORT}" ]]; then
  if ! pgrep -af "python3 -m http.server ${PORT} .*--directory ${OUT_DIR}" >/dev/null 2>&1; then
    nohup python3 -m http.server "${PORT}" --bind 0.0.0.0 --directory "${OUT_DIR}" \
      >"${SERVER_LOG}" 2>&1 </dev/null &
    sleep 1
  fi
fi

IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)"
[[ -n "${IP}" ]] || IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"

TMP="$(mktemp)"
trap 'rm -f "${TMP}"' EXIT
{
  echo "DOWNLOAD_STATUS=READY"
  echo "ARCHIVE=${ARCHIVE}"
  echo "SHA256_FILE=${SHA_FILE}"
  if [[ -n "${PORT}" && -n "${IP}" ]]; then
    echo "LOCAL_ARCHIVE_URL=http://${IP}:${PORT}/${ARCHIVE_NAME}"
    echo "LOCAL_SHA256_URL=http://${IP}:${PORT}/${SHA_NAME}"
    echo "LOCAL_SERVER_PORT=${PORT}"
  else
    echo "LOCAL_LINK_STATUS=UNAVAILABLE"
  fi
} > "${TMP}"

if [[ "${PUBLIC_UPLOAD}" == "1" ]] && command -v curl >/dev/null 2>&1; then
  RESPONSE="$(curl -fsS --connect-timeout 20 --max-time 180 \
    -X POST https://tempfile.org/api/upload/local \
    -F "files=@${ARCHIVE}" \
    -F "files=@${SHA_FILE}" \
    -F "expiryHours=${EXPIRY_HOURS}" 2>/dev/null || true)"
  if [[ -n "${RESPONSE}" ]]; then
    PARSED="$(python3 - "${ARCHIVE_NAME}" "${SHA_NAME}" <<'PY' <<<"${RESPONSE}" 2>/dev/null || true
import json, sys
archive_name, sha_name = sys.argv[1:3]
data = json.load(sys.stdin)
files = data.get("files", [])
by_name = {item.get("name"): item.get("url") for item in files}
archive_url = by_name.get(archive_name, "")
sha_url = by_name.get(sha_name, "")
if archive_url:
    print("PUBLIC_ARCHIVE_URL=" + archive_url)
if sha_url:
    print("PUBLIC_SHA256_URL=" + sha_url)
PY
)"
    if grep -q '^PUBLIC_ARCHIVE_URL=' <<<"${PARSED}"; then
      {
        echo "PUBLIC_UPLOAD_STATUS=READY"
        echo "PUBLIC_LINKS_EXPIRE_HOURS=${EXPIRY_HOURS}"
        echo "${PARSED}"
      } >> "${TMP}"
    else
      echo "PUBLIC_UPLOAD_STATUS=FAILED" >> "${TMP}"
    fi
  else
    echo "PUBLIC_UPLOAD_STATUS=FAILED" >> "${TMP}"
  fi
else
  echo "PUBLIC_UPLOAD_STATUS=DISABLED" >> "${TMP}"
fi

cp -f "${TMP}" "${LINKS_FILE}"
cat "${LINKS_FILE}"
echo "DOWNLOAD_LINKS_FILE=${LINKS_FILE}"
