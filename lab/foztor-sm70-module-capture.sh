#!/usr/bin/env bash
set -Eeuo pipefail

# Capture the decoded CUDA module that official Foztor hoo_gpu passes to the
# NVIDIA driver. The public package stores per-arch payloads in an HOC1
# container; this harness observes the already-decoded image at cuModuleLoadData.
# It does not modify the Foztor binary and restores the HiveOS miner on exit.

FOZTOR_URL="${FOZTOR_URL:-https://htn.foztor.net/hoo_gpu.tar.gz}"
WORK="${FOZTOR_CAPTURE_WORK:-/tmp/pepew-foztor-capture}"
OUT="${FOZTOR_CAPTURE_OUT:-/hive-config/foztor-report}"
GPU_ID="${FOZTOR_GPU_ID:-0}"
CAPTURE_TIMEOUT="${FOZTOR_CAPTURE_TIMEOUT:-75}"
EXP_THRESHOLD="${FOZTOR_EXP_THRESHOLD:-1.5}"

if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo 'ERROR: run as root on the HiveOS worker' >&2
  exit 2
fi
for cmd in gcc curl tar find timeout grep strings; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: missing $cmd" >&2; exit 2; }
done
[[ -f /hive-config/wallet.conf ]] || { echo 'ERROR: /hive-config/wallet.conf not found' >&2; exit 2; }

# shellcheck disable=SC1091
source /hive-config/wallet.conf
POOL="${CUSTOM_URL:-}"
USER="${CUSTOM_TEMPLATE:-}"
PASS="${CUSTOM_PASS:-x}"
[[ -n "$POOL" && -n "$USER" ]] || { echo 'ERROR: active Flight Sheet lacks CUSTOM_URL/CUSTOM_TEMPLATE' >&2; exit 2; }

rm -rf "$WORK"
mkdir -p "$WORK/pkg" "$WORK/dumps" "$OUT"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"

cat > "$WORK/dump_cuda_module.c" <<'EOF'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef int CUresult;
typedef void *CUmodule;
typedef int CUjit_option;

static unsigned dump_seq = 0;

static size_t elf64_size(const unsigned char *p) {
    const Elf64_Ehdr *eh = (const Elf64_Ehdr *)p;
    if (memcmp(eh->e_ident, ELFMAG, SELFMAG) != 0 || eh->e_ident[EI_CLASS] != ELFCLASS64) return 0;
    size_t end = sizeof(*eh);
    if (eh->e_phoff && eh->e_phentsize >= sizeof(Elf64_Phdr) && eh->e_phnum < 4096) {
        size_t table = (size_t)eh->e_phoff + (size_t)eh->e_phentsize * eh->e_phnum;
        if (table > end) end = table;
        const Elf64_Phdr *ph = (const Elf64_Phdr *)(p + eh->e_phoff);
        for (unsigned i = 0; i < eh->e_phnum; ++i) {
            size_t x = (size_t)ph[i].p_offset + (size_t)ph[i].p_filesz;
            if (x > end) end = x;
        }
    }
    if (eh->e_shoff && eh->e_shentsize >= sizeof(Elf64_Shdr) && eh->e_shnum < 65536) {
        size_t table = (size_t)eh->e_shoff + (size_t)eh->e_shentsize * eh->e_shnum;
        if (table > end) end = table;
        const Elf64_Shdr *sh = (const Elf64_Shdr *)(p + eh->e_shoff);
        for (unsigned i = 0; i < eh->e_shnum; ++i) {
            if (sh[i].sh_type == SHT_NOBITS) continue;
            size_t x = (size_t)sh[i].sh_offset + (size_t)sh[i].sh_size;
            if (x > end) end = x;
        }
    }
    if (end < sizeof(*eh) || end > (256u * 1024u * 1024u)) return 0;
    return end;
}

static uint16_t rd16(const unsigned char *p) { uint16_t v; memcpy(&v,p,sizeof(v)); return v; }
static uint32_t rd32(const unsigned char *p) { uint32_t v; memcpy(&v,p,sizeof(v)); return v; }
static uint64_t rd64(const unsigned char *p) { uint64_t v; memcpy(&v,p,sizeof(v)); return v; }

static size_t image_size(const void *image, const char **kind) {
    const unsigned char *p = (const unsigned char *)image;
    if (!p) return 0;
    if (p[0] == 0x7f && p[1] == 'E' && p[2] == 'L' && p[3] == 'F') {
        *kind = "elf-cubin";
        return elf64_size(p);
    }
    /* CUDA fatBinaryHeader: magic, version, headerSize, fatSize. */
    if (rd32(p) == 0xba55ed50u) {
        uint16_t hs = rd16(p + 6);
        uint64_t fs = rd64(p + 8);
        uint64_t total = (uint64_t)hs + fs;
        if (hs >= 16 && total <= 256u * 1024u * 1024u) {
            *kind = "fatbin";
            return (size_t)total;
        }
    }
    if (!memcmp(p, ".version", 8) || !memcmp(p, "//", 2)) {
        size_t n = strnlen((const char *)p, 64u * 1024u * 1024u);
        if (n < 64u * 1024u * 1024u) { *kind = "ptx"; return n + 1; }
    }
    *kind = "unknown";
    return 0;
}

static void dump_image(const void *image) {
    const char *kind = NULL;
    size_t n = image_size(image, &kind);
    if (!n) {
        fprintf(stderr, "[PEPEW-CAPTURE] cuModuleLoadData image type unsupported/unknown\n");
        return;
    }
    const char *dir = getenv("PEPEW_CUDA_DUMP_DIR");
    if (!dir || !*dir) dir = "/tmp/pepew-foztor-capture/dumps";
    char path[512];
    snprintf(path, sizeof(path), "%s/module-%03u-%s.bin", dir, dump_seq++, kind);
    int fd = open(path, O_CREAT|O_TRUNC|O_WRONLY, 0644);
    if (fd < 0) { fprintf(stderr, "[PEPEW-CAPTURE] open %s: %s\n", path, strerror(errno)); return; }
    const unsigned char *p = (const unsigned char *)image;
    size_t off = 0;
    while (off < n) {
        ssize_t w = write(fd, p + off, n - off);
        if (w <= 0) break;
        off += (size_t)w;
    }
    close(fd);
    fprintf(stderr, "[PEPEW-CAPTURE] dumped %s: %zu bytes (%s)\n", path, off, kind);
}

CUresult cuModuleLoadData(CUmodule *module, const void *image) {
    typedef CUresult (*fn_t)(CUmodule *, const void *);
    static fn_t real_fn = NULL;
    if (!real_fn) real_fn = (fn_t)dlsym(RTLD_NEXT, "cuModuleLoadData");
    dump_image(image);
    if (!real_fn) return 999;
    return real_fn(module, image);
}

CUresult cuModuleLoadDataEx(CUmodule *module, const void *image, unsigned int numOptions,
                            CUjit_option *options, void **optionValues) {
    typedef CUresult (*fn_t)(CUmodule *, const void *, unsigned int, CUjit_option *, void **);
    static fn_t real_fn = NULL;
    if (!real_fn) real_fn = (fn_t)dlsym(RTLD_NEXT, "cuModuleLoadDataEx");
    dump_image(image);
    if (!real_fn) return 999;
    return real_fn(module, image, numOptions, options, optionValues);
}
EOF

gcc -shared -fPIC -O2 -Wall -Wextra "$WORK/dump_cuda_module.c" -o "$WORK/libpepew_cuda_capture.so" -ldl

echo '=== DOWNLOAD OFFICIAL FOZTOR ==='
curl -fL --retry 3 --connect-timeout 20 "$FOZTOR_URL" -o "$WORK/hoo_gpu.tar.gz"
tar -xzf "$WORK/hoo_gpu.tar.gz" -C "$WORK/pkg"
FOZTOR_BIN="$(find "$WORK/pkg" -type f -name hoo_gpu | head -n1 || true)"
[[ -n "$FOZTOR_BIN" ]] || { echo 'ERROR: hoo_gpu not found' >&2; exit 3; }
chmod +x "$FOZTOR_BIN"
FOZTOR_DIR="$(dirname "$FOZTOR_BIN")"

restore_miner() {
  set +e
  [[ -n "${FPID:-}" ]] && kill "$FPID" 2>/dev/null || true
  [[ -n "${FPID:-}" ]] && wait "$FPID" 2>/dev/null || true
  command -v miner >/dev/null 2>&1 && miner start >/dev/null 2>&1 || true
}
trap restore_miner EXIT INT TERM

command -v miner >/dev/null 2>&1 && miner stop >/dev/null 2>&1 || true
sleep 3

export PEPEW_CUDA_DUMP_DIR="$WORK/dumps"
export LD_LIBRARY_PATH="$FOZTOR_DIR:$FOZTOR_DIR/lib:${LD_LIBRARY_PATH:-}"
export LD_PRELOAD="$WORK/libpepew_cuda_capture.so"

cd "$FOZTOR_DIR"
echo '=== START FOZTOR MODULE CAPTURE ==='
echo "Waiting up to ${CAPTURE_TIMEOUT}s for decoded CUDA module..."
./hoo_gpu -o "$POOL" -u "$USER" -p "$PASS" --pepepow --gpu-id "$GPU_ID" \
  --exp-threshold "$EXP_THRESHOLD" --no-share-hashrate --same-stratum --reset-autotune \
  >"$WORK/foztor.log" 2>&1 &
FPID=$!

found=0
for ((s=0; s<CAPTURE_TIMEOUT; s+=2)); do
  if find "$WORK/dumps" -type f -size +4k | grep -q .; then
    found=1
    break
  fi
  kill -0 "$FPID" 2>/dev/null || break
  sleep 2
done

kill "$FPID" 2>/dev/null || true
wait "$FPID" 2>/dev/null || true
unset LD_PRELOAD
FPID=""

if (( ! found )); then
  echo 'ERROR: no decoded module was captured.' >&2
  tail -n 120 "$WORK/foztor.log" >&2 || true
  exit 4
fi

META="$WORK/capture-meta.txt"
{
  echo "run_id=$RUN_ID"
  echo "gpu_id=$GPU_ID"
  echo "exp_threshold=$EXP_THRESHOLD"
  echo
  find "$WORK/dumps" -type f -maxdepth 1 -print -exec wc -c {} \;
  echo
  echo '=== kernel/symbol strings ==='
  for f in "$WORK"/dumps/*; do
    echo "--- $f ---"
    strings -a "$f" | grep -Eai 'pepew|hoo|kernel|exp|lut|mat|target|nonce|magic' | head -n 300 || true
  done
} > "$META"

cp "$WORK/foztor.log" "$WORK/foztor.redacted.log"
python3 - "$WORK/foztor.redacted.log" "$USER" "$POOL" "$PASS" <<'PY' 2>/dev/null || true
import sys
p,user,pool,pw=sys.argv[1:]
s=open(p,'r',errors='replace').read()
for old,new in ((user,'<USER_REDACTED>'),(pool,'<POOL_REDACTED>'),(pw,'<PASS_REDACTED>')):
    if old: s=s.replace(old,new)
open(p,'w').write(s)
PY

REPORT="$OUT/foztor-sm70-decoded-$RUN_ID.tar.gz"
tar -C "$WORK" -czf "$REPORT" dumps capture-meta.txt foztor.redacted.log

echo
echo '=== CAPTURE COMPLETE ==='
ls -lh "$WORK/dumps"/* "$REPORT"
echo "Report: $REPORT"
echo 'Upload this .tar.gz to ChatGPT.'
