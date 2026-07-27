#!/usr/bin/env python3
"""Apply the deterministic v0.4.0 release profile before the CUDA build.

The script is intentionally idempotent. It converts the terminal UI to
Hive-shell-safe text, restores the higher-throughput runtime batch, publishes
per-device status fields, and makes the CUDA launch width a build-time profile.
"""

from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MAIN = ROOT / "native/src/app/main.cpp"
CUDA = ROOT / "native/src/cuda/header80_backend.cu"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"release source preparation failed: {label}")
    return text.replace(old, new, 1)


def prepare_main() -> None:
    text = MAIN.read_text(encoding="utf-8")

    text = replace_once(
        text,
        '            << "            🐸 " << kBold << kGreen << "PepeW Miner" << kReset << " 🐸\\n"',
        '            << "              " << kBold << kGreen << "PepeW Miner" << kReset << "\\n"',
        "terminal title",
    )
    text = replace_once(
        text,
        '            << kCyan << "GPU       : " << kReset << gpu_name << "\\n\\n"',
        '            << kCyan << "GPU 0     : " << kReset << gpu_name << "\\n\\n"',
        "GPU label",
    )
    text = replace_once(
        text,
        '            << kYellow << "\\"PepeW — твоя монета. Твои правила.\\"\\n\\n" << kReset',
        '            << kYellow << "\\"PepeW - твоя монета. Твои правила.\\"\\n\\n" << kReset',
        "ASCII-safe slogan punctuation",
    )

    replacements = {
        '"🟣 HOOHASH"': '"[HOOHASH]"',
        '"🔵 POOL"': '"[POOL]"',
        '"✅ READY"': '"[READY]"',
        '"🟡 DIFF"': '"[DIFF]"',
        '"🔄 JOB"': '"[JOB]"',
        '"💰 ACCEPTED"': '"[ACCEPTED]"',
        '"❌ REJECTED"': '"[REJECTED]"',
        '"🐸 🔨 Mining"': '"[MINING]"',
        '"🔴 ERROR"': '"[ERROR]"',
        '"⚪ STOP      "': '"[STOP] "',
        '"🔴 FATAL     "': '"[FATAL] "',
    }
    for old, new in replacements.items():
        if old in text:
            text = text.replace(old, new)

    text = text.replace('"  •  "', '" | "')
    text = text.replace('"  •  💰 A "', '" | A "')
    text = text.replace('"  •  ❌ R "', '" | R "')
    text = text.replace('"  •  ⏱ "', '" | Uptime "')
    text = text.replace('"   Consensus V110 verified\\n"', '" Consensus V110 verified\\n"')
    text = text.replace('"      Connected\\n"', '" Connected\\n"')
    text = text.replace('"      Subscribed\\n"', '" Subscribed\\n"')
    text = text.replace('"     Pool authorization complete\\n"', '" Pool authorization complete\\n"')
    text = text.replace('"      "', '" "')
    text = text.replace('"       "', '" "')
    text = text.replace('"  "', '" "')

    text = replace_once(
        text,
        '            output << "HPS=" << hps << \'\\n\'\n'
        '                   << "ACCEPTED=" << stats.accepted << \'\\n\'',
        '            output << "HPS=" << hps << \'\\n\'\n'
        '                   << "GPU_COUNT=1\\n"\n'
        '                   << "GPU0_HPS=" << hps << \'\\n\'\n'
        '                   << "ACCEPTED=" << stats.accepted << \'\\n\'',
        "per-device runtime status",
    )

    text = replace_once(
        text,
        '        // 262K keeps the optimized GPU path saturated while reducing stale-job\n'
        '        // exposure to roughly half of the earlier 524K validation batch.\n'
        '        constexpr std::uint64_t chunk_size = 262144;',
        '        // 524K restores the higher-throughput launch profile. At the measured\n'
        '        // rate it still keeps clean-job switch latency below one second.\n'
        '        constexpr std::uint64_t chunk_size = 524288;',
        "runtime batch",
    )

    text = replace_once(
        text,
        '                  "gpu_target_filter=1 blake3_midstate=1");',
        '                  "gpu_target_filter=1 blake3_midstate=1 "\n'
        '                  "batch=524288 gpu_stats=per_device");',
        "release telemetry markers",
    )

    forbidden = ("🐸", "🔨", "💰", "❌", "⏱", "🟣", "🔵", "✅", "🟡", "🔄", "🔴", "⚪", "•")
    present = [value for value in forbidden if value in text]
    if present:
        raise SystemExit(f"unsupported terminal glyphs remain: {present}")
    for required in ("GPU_COUNT=1", "GPU0_HPS=", "chunk_size = 524288", "[MINING]"):
        if required not in text:
            raise SystemExit(f"release source preparation missing marker: {required}")

    MAIN.write_text(text, encoding="utf-8")


def prepare_cuda() -> None:
    text = CUDA.read_text(encoding="utf-8")
    text = replace_once(
        text,
        'namespace {\n\nconstexpr std::size_t kHashSize = 32;',
        'namespace {\n\n#ifndef PEPEPOW_CUDA_THREADS\n#define PEPEPOW_CUDA_THREADS 128\n#endif\n\nconstexpr std::size_t kHashSize = 32;',
        "CUDA launch-width macro",
    )
    text = replace_once(
        text,
        '    constexpr unsigned int threads = 128U;',
        '    constexpr unsigned int threads = static_cast<unsigned int>(PEPEPOW_CUDA_THREADS);',
        "CUDA launch-width use",
    )
    for required in ("PEPEPOW_CUDA_THREADS", "--fmad=false"):
        if required == "--fmad=false":
            continue
        if required not in text:
            raise SystemExit(f"CUDA release source missing marker: {required}")
    CUDA.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    prepare_main()
    prepare_cuda()
    print("PASS: v0.4.0 release source profile applied")
