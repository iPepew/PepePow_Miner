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
    cmake = root / "native/CMakeLists.txt"
    run = root / "hiveos/h-run.sh"

    for path in (main_cpp, cmake, run):
        if not path.is_file():
            raise SystemExit(f"ERROR: required file missing: {path}")

    cmake_text = cmake.read_text(encoding="utf-8")
    cmake_text = cmake_text.replace(
        "project(PepePowMiner VERSION 1.0.0 LANGUAGES C CXX)",
        "project(PepePowMiner VERSION 1.0.1 LANGUAGES C CXX)",
        1,
    )
    cmake.write_text(cmake_text, encoding="utf-8")

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
            << kYellow << "         PepeW - твоя монета, твои правила.\n" << kReset
            << kCyan << "              https://t.me/pepepow_ru\n" << kReset
            << kBrightGreen << "------------------------------------------------------------\n" << kReset
            << kCyan << " Algorithm : " << kReset << "PEPEPOW HooHash V110\n"
            << kCyan << " Engine    : " << kReset << "service768 / CUDA sm_86\n"
            << kCyan << " Live mode : " << kReset << "Turbo / batch 1048576\n"
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

    old_chunk = '''        // 262K keeps the optimized GPU path saturated while reducing stale-job
        // exposure to roughly half of the earlier 524K validation batch.
        constexpr std::uint64_t chunk_size = 262144;'''
    new_chunk = '''        // Production-tuned runtime batch. The larger batch amortizes launch,
        // job preparation and status overhead on the verified service768 path.
        const std::uint64_t chunk_size = [] {
            constexpr std::uint64_t fallback = 1048576ULL;
            const char* raw = std::getenv("PEPEW_BATCH_SIZE");
            if (raw == nullptr || *raw == '\\0') return fallback;
            char* end = nullptr;
            const unsigned long long parsed = std::strtoull(raw, &end, 10);
            if (end == raw || *end != '\\0' || parsed < 262144ULL || parsed > 4194304ULL) {
                return fallback;
            }
            return static_cast<std::uint64_t>(parsed);
        }();'''
    text = replace_once(text, old_chunk, new_chunk, "runtime batch")

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

    run_text = run.read_text(encoding="utf-8")
    if 'export LANG="${LANG:-C.UTF-8}"' not in run_text:
        run_text = run_text.replace(
            "set -euo pipefail\n",
            "set -euo pipefail\nexport LANG=\"${LANG:-C.UTF-8}\"\nexport LC_ALL=\"${LC_ALL:-C.UTF-8}\"\n",
            1,
        )
    locale_anchor = 'export LC_ALL="${LC_ALL:-C.UTF-8}"\n'
    turbo_env = (
        'export PEPEW_BATCH_SIZE="${PEPEW_BATCH_SIZE:-1048576}"\n'
        'export PEPEW_DIAGNOSTIC="${PEPEW_DIAGNOSTIC:-0}"\n'
    )
    if turbo_env not in run_text:
        run_text = run_text.replace(locale_anchor, locale_anchor + turbo_env, 1)
    run_text = run_text.replace(
        "OPTIMIZATION=AUTOTUNED_PIPELINE EXACT_BIT_CONVERSIONS BIT_SW_FRACTION SCALED_NIBBLE_TABLE ASSUME_FINITE HASHMOD_HOIST PREFER_L1",
        "OPTIMIZATION=SERVICE768 TURBO_RUNTIME HIVEOS_KHS_TELEMETRY EXACT_BIT_CONVERSIONS BIT_SW_FRACTION SCALED_NIBBLE_TABLE ASSUME_FINITE PREFER_L1",
    )
    run_text = run_text.replace(
        "Optimizations: autotuned monolithic/split pipeline; exact bit conversions; direct bit fraction(sum/1024); optional cell-major scaled-nibble lookup; finite-domain nonlinear fast path; hash-mod conversion hoist; PreferL1; persistent buffers; 524288 runtime batch",
        "Optimizations: service768; turbo batch=${PEPEW_BATCH_SIZE}; native HiveOS khs telemetry; exact FP64; CPU share verification",
    )
    run_text = run_text.replace(
        "  printf './pepepowminer'\n  printf ' %q' \"${PEPEPOW_ARGS[@]}\"\n  echo",
        '  echo "./pepepowminer [arguments supplied by HiveOS]"',
    )
    run.write_text(run_text, encoding="utf-8")

    print("V101_SOURCE_PATCH=PASS")
    print("VERSION=1.0.1")
    print("CONSOLE_ENCODING=ASCII_ICONS_UTF8_TEXT")
    print("PEPEW_BATCH_SIZE=1048576")
    print("HIVEOS_HASHRATE_SCHEMA=KHS_NATIVE")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
