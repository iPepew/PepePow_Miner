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
            << kYellow << "         PepeW — твоя монета. Твои правила.\n" << kReset
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
    text = replace_once(text, old_identity, new_identity, "build identity")
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

    stats_text = stats.read_text(encoding="utf-8")
    stats_text = stats_text.replace('"ver":""', '"ver":"1.0.0"')
    stats.write_text(stats_text, encoding="utf-8")

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
    print("VERSION=1.0.0")
    print("PACKAGE_ROOT=PepeW-Miner-v1.0.0-HiveOS")
    print("TELEGRAM=https://t.me/pepepow_ru")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
