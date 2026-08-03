#!/usr/bin/env python3
from __future__ import annotations

import sys
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"ERROR: {label} anchor not found")
    return text.replace(old, new, 1)


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} SOURCE_ROOT", file=sys.stderr)
        return 2

    root = Path(sys.argv[1]).resolve()
    main_cpp = root / "native/src/app/main.cpp"
    manifest = root / "hiveos/h-manifest.conf"
    stats = root / "hiveos/h-stats.sh"
    config = root / "hiveos/h-config.sh"
    run = root / "hiveos/h-run.sh"

    for path in (main_cpp, manifest, stats, config, run):
        if not path.is_file():
            raise SystemExit(f"ERROR: required file missing: {path}")

    text = main_cpp.read_text(encoding="utf-8")
    start_anchor = "    static void banner(std::string_view gpu_name) {"
    end_anchor = "    static void render(std::string_view message) {"
    start = text.find(start_anchor)
    end = text.find(end_anchor, start)
    if start < 0 or end < 0:
        raise SystemExit("ERROR: ConsoleUi banner anchors not found")

    banner = r'''    static void banner(std::string_view gpu_name) {
        std::cout
            << kBrightGreen << "============================================================\n" << kReset
            << kBold << kGreen << "                 PEPEW MINER v" << PEPEPOW_VERSION << "\n" << kReset
            << kBrightGreen << "============================================================\n" << kReset
            << kYellow << "         PepeW - твоя монета. Твои правила.\n" << kReset
            << kCyan << "              https://t.me/pepepow_ru\n" << kReset
            << kBrightGreen << "------------------------------------------------------------\n" << kReset
            << kCyan << " Algorithm : " << kReset << "PEPEPOW HooHash V110\n"
            << kCyan << " Engine    : " << kReset << "service768 / CUDA sm_86\n"
            << kCyan << " GPU       : " << kReset << gpu_name << '\n'
            << kCyan << " Security  : " << kReset << "GPU result + CPU share verification\n"
            << kBrightGreen << "============================================================\n" << kReset
            << std::flush;
    }

'''
    text = text[:start] + banner + text[end:]

    old_identity = '''std::string build_identity() {
    return std::string("PepeW Performance & Stability Edition ") + PEPEPOW_VERSION +
           " commit=" + PEPEPOW_GIT_COMMIT + " build=Release";
}'''
    new_identity = '''std::string build_identity() {
    return std::string("PepeW Miner v") + PEPEPOW_VERSION +
           " | PEPEPOW HooHash V110 | service768 | HiveOS sm_86" +
           " | https://t.me/pepepow_ru" +
           " | commit=" + PEPEPOW_GIT_COMMIT + " | build=Release";
}'''
    if old_identity in text:
        text = replace_once(text, old_identity, new_identity, "build identity")
    elif new_identity not in text:
        raise SystemExit("ERROR: build identity is neither original nor branded")

    glyph_replacements = {
        "🟣 HOOHASH": "[HOOHASH]",
        "🔵 POOL": "[POOL]",
        "✅ READY": "[READY]",
        "🟡 DIFF": "[DIFF]",
        "🔄 JOB": "[JOB]",
        "💰 ACCEPTED": "[ACCEPTED]",
        "❌ REJECTED": "[REJECTED]",
        "🐸 🔨 Mining": "[MINING]",
        "🔴 ERROR": "[ERROR]",
        "⚪ STOP": "[STOP]",
        "🔴 FATAL": "[FATAL]",
        "  •  ": "  |  ",
        "💰 A ": "A ",
        "❌ R ": "R ",
        "⏱ ": "UP ",
    }
    for old, new in glyph_replacements.items():
        text = text.replace(old, new)
    main_cpp.write_text(text, encoding="utf-8")

    manifest.write_text(
        "CUSTOM_NAME=PepeW-Miner\n"
        "CUSTOM_VERSION=1.0.0\n"
        "MINER_NAME=$CUSTOM_NAME\n"
        "MINER_VERSION=$CUSTOM_VERSION\n"
        "CUSTOM_CONFIG_FILENAME=/hive/miners/custom/PepeW-Miner-v1.0.0-HiveOS/config.txt\n"
        "MINER_CONFIG_FILENAME=$CUSTOM_CONFIG_FILENAME\n"
        "CUSTOM_LOG_BASENAME=/var/log/miner/custom/PepeW-Miner\n"
        "MINER_API_PORT=4049\n",
        encoding="utf-8",
    )

    stats.write_text(r'''#!/usr/bin/env bash
set -u

miner_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
status_file="${miner_dir}/miner-status.env"
miner_pid_file="${miner_dir}/miner.pid"

read_numeric() {
  local key="$1" value=""
  if [[ -r "${status_file}" ]]; then
    value="$(sed -n "s/^${key}=//p" "${status_file}" 2>/dev/null | tail -n1)"
  fi
  [[ "${value}" =~ ^[0-9]+$ ]] && printf '%s' "${value}" || printf '0'
}

accepted="$(read_numeric ACCEPTED)"
rejected="$(read_numeric REJECTED)"
uptime="$(read_numeric UPTIME)"
updated="$(read_numeric UPDATED_EPOCH)"
status_pid="$(read_numeric PID)"
total_hps="$(read_numeric HPS)"
gpu_count="$(read_numeric GPU_COUNT)"

if [[ ! "${gpu_count}" =~ ^[1-9][0-9]*$ ]] || [[ ${gpu_count} -gt 16 ]]; then
  gpu_count="$(nvidia-smi -L 2>/dev/null | grep -c '^GPU ' || true)"
fi
[[ "${gpu_count}" =~ ^[1-9][0-9]*$ ]] || gpu_count=1

file_pid=0
if [[ -r "${miner_pid_file}" ]]; then
  candidate="$(tr -dc '0-9' < "${miner_pid_file}" 2>/dev/null || true)"
  [[ "${candidate}" =~ ^[0-9]+$ ]] && file_pid="${candidate}"
fi

pid=0
for candidate in "${status_pid}" "${file_pid}"; do
  if [[ "${candidate}" =~ ^[1-9][0-9]*$ ]] && kill -0 "${candidate}" 2>/dev/null; then
    exe="$(readlink -f "/proc/${candidate}/exe" 2>/dev/null || true)"
    if [[ "${exe}" == "${miner_dir}/pepepowminer" ]]; then
      pid="${candidate}"
      break
    fi
  fi
done

now="$(date +%s)"
fresh=1
if [[ ${pid} -eq 0 || ${updated} -eq 0 || ${now} -lt ${updated} || $((now - updated)) -gt 30 ]]; then
  fresh=0
fi
if [[ ${pid} -eq 0 ]]; then
  uptime=0
else
  process_uptime="$(ps -o etimes= -p "${pid}" 2>/dev/null | tr -d ' ' || true)"
  [[ "${process_uptime}" =~ ^[0-9]+$ ]] && uptime="${process_uptime}"
fi
[[ ${fresh} -eq 1 ]] || total_hps=0

declare -a gpu_khs gpu_temp gpu_fan gpu_bus
for ((i=0; i<gpu_count; ++i)); do
  device_hps="$(read_numeric "GPU${i}_HPS")"
  if [[ ${device_hps} -eq 0 && ${i} -eq 0 ]]; then
    device_hps="${total_hps}"
  fi
  [[ ${fresh} -eq 1 ]] || device_hps=0
  gpu_khs[$i]=$((device_hps / 1000))
  gpu_temp[$i]=0
  gpu_fan[$i]=0
  gpu_bus[$i]="${i}"
done

trim_field() {
  local value="$1"
  value="${value#${value%%[![:space:]]*}}"
  value="${value%${value##*[![:space:]]}}"
  printf '%s' "${value}"
}

while IFS=',' read -r raw_index raw_bus raw_temp raw_fan; do
  index="$(trim_field "${raw_index}")"
  [[ "${index}" =~ ^[0-9]+$ ]] || continue
  (( index < gpu_count )) || continue
  temp="$(trim_field "${raw_temp}")"
  fan="$(trim_field "${raw_fan}")"
  bus="$(trim_field "${raw_bus}")"
  [[ "${temp}" =~ ^[0-9]+$ ]] && gpu_temp[$index]="${temp}"
  [[ "${fan}" =~ ^[0-9]+$ ]] && gpu_fan[$index]="${fan}"
  bus_tail="${bus#*:}"
  bus_hex="${bus_tail%%:*}"
  if [[ "${bus_hex}" =~ ^[0-9A-Fa-f]{1,2}$ ]]; then
    gpu_bus[$index]=$((16#${bus_hex}))
  fi
done < <(nvidia-smi --query-gpu=index,pci.bus_id,temperature.gpu,fan.speed --format=csv,noheader,nounits 2>/dev/null || true)

array_json() { local IFS=,; printf '[%s]' "$*"; }
hs_json="$(array_json "${gpu_khs[@]}")"
temp_json="$(array_json "${gpu_temp[@]}")"
fan_json="$(array_json "${gpu_fan[@]}")"
bus_json="$(array_json "${gpu_bus[@]}")"

khs=0
for value in "${gpu_khs[@]}"; do khs=$((khs + value)); done

stats=$(printf '{"hs":%s,"hs_units":"khs","temp":%s,"fan":%s,"uptime":%s,"ar":[%s,%s,0],"bus_numbers":%s,"ver":"1.0.0","algo":"hoohash"}' \
  "${hs_json}" "${temp_json}" "${fan_json}" "${uptime}" \
  "${accepted}" "${rejected}" "${bus_json}")
''', encoding="utf-8")

    config_text = config.read_text(encoding="utf-8")
    config_text = config_text.replace('echo "Upstream pool: ${pool}"', 'echo "Upstream pool: configured via HiveOS"')
    config_text = config_text.replace('echo "User: ${user}"', 'echo "User: configured via HiveOS"')
    config_text = config_text.replace('echo "Password: ${pass}"', 'echo "Password: configured via HiveOS"')
    config_text = config_text.replace('echo "Extra config: ${extra_raw}"', 'echo "Extra config: ${extra_raw:+configured}"')
    config_text = config_text.replace(
        "  printf 'Final miner command: ./pepepowminer'\n  printf ' %q' \"${args[@]}\"\n  echo",
        '  echo "Final miner command: ./pepepowminer [credentials supplied by HiveOS]"',
    )
    config.write_text(config_text, encoding="utf-8")

    run_text = run.read_text(encoding="utf-8")
    if 'export LANG="${LANG:-C.UTF-8}"' not in run_text:
        run_text = run_text.replace(
            'set -euo pipefail\n',
            'set -euo pipefail\nexport LANG="${LANG:-C.UTF-8}"\nexport LC_ALL="${LC_ALL:-C.UTF-8}"\n',
            1,
        )
    run_text = run_text.replace(
        "OPTIMIZATION=AUTOTUNED_PIPELINE EXACT_BIT_CONVERSIONS BIT_SW_FRACTION SCALED_NIBBLE_TABLE ASSUME_FINITE HASHMOD_HOIST PREFER_L1",
        "OPTIMIZATION=SERVICE768 BLOCK_COMPACTED_COLD_PATH EXACT_BIT_CONVERSIONS BIT_SW_FRACTION SCALED_NIBBLE_TABLE ASSUME_FINITE PREFER_L1",
    )
    run_text = run_text.replace(
        "Optimizations: autotuned monolithic/split pipeline; exact bit conversions; direct bit fraction(sum/1024); optional cell-major scaled-nibble lookup; finite-domain nonlinear fast path; hash-mod conversion hoist; PreferL1; persistent buffers; 524288 runtime batch",
        "Optimizations: service768 block-compacted cold path; exact FP64 selectors; scaled-nibble table; GPU target filter; CPU share verification",
    )
    run_text = run_text.replace(
        "  printf './pepepowminer'\n  printf ' %q' \"${PEPEPOW_ARGS[@]}\"\n  echo",
        '  echo "./pepepowminer [arguments supplied by HiveOS]"',
    )
    run.write_text(run_text, encoding="utf-8")

    print("BEAUTIFUL_SOURCE_PATCH=PASS")
    print("CONSOLE_ENCODING=ASCII_ICONS_UTF8_TEXT")
    print("HIVEOS_HASHRATE=KHS_PER_GPU")
    print("VERSION=1.0.0")
    print("PACKAGE_ROOT=PepeW-Miner-v1.0.0-HiveOS")
    print("TELEGRAM=https://t.me/pepepow_ru")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
