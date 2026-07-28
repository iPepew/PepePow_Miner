#!/usr/bin/env python3
"""Apply the deterministic v0.5.0 CUDA word-pipeline release profile.

The profile keeps the proven v0.4.0 HiveOS/runtime fixes, replaces the byte-heavy
CUDA backend with a word-oriented BLAKE3/HooHash pipeline, adds a 32 KiB scaled
matrix constant cache, caches per-job device uploads, and extends exact CPU/CUDA
validation. The script is idempotent.
"""

from __future__ import annotations

from pathlib import Path
import runpy

ROOT = Path(__file__).resolve().parents[1]
MAIN = ROOT / "native/src/app/main.cpp"
HEADER = ROOT / "native/include/pepepow/cuda/header80_backend.hpp"
CMAKE = ROOT / "native/CMakeLists.txt"
VALIDATION = ROOT / "native/tests/cuda_header80_validation.cpp"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"v0.5.0 source preparation failed: {label}")
    return text.replace(old, new, 1)


def apply_v040_profile() -> None:
    runpy.run_path(str(ROOT / "hiveos/prepare-v040-source.py"), run_name="__main__")


def prepare_main() -> None:
    text = MAIN.read_text(encoding="utf-8")
    text = replace_once(
        text,
        'return std::string("PepeW Performance & Stability Edition ") + PEPEPOW_VERSION +',
        'return std::string("PepeW Warp Pipeline Edition ") + PEPEPOW_VERSION +',
        "build identity",
    )
    text = replace_once(
        text,
        '            << kYellow << "\\"PepeW - твоя монета. Твои правила.\\"\\n\\n" << kReset',
        '            << kYellow << "\\"PepeW - твоя монета. Твои правила.\\"\\n" << kReset\n'
        '            << kCyan << "Telegram  : https://t.me/pepepow_ru\\n\\n" << kReset',
        "Telegram group banner",
    )
    text = replace_once(
        text,
        '                  "batch=524288 gpu_stats=per_device");',
        '                  "batch=524288 gpu_stats=per_device word_pipeline=1 "\n'
        '                  "scaled_matrix=autotune upload_cache=1");',
        "runtime optimization markers",
    )
    MAIN.write_text(text, encoding="utf-8")


def prepare_header() -> None:
    text = HEADER.read_text(encoding="utf-8")
    text = replace_once(
        text,
        '    void* device_result_{nullptr};\n',
        '    void* device_result_{nullptr};\n'
        '    void* device_matrix_{nullptr};\n',
        "persistent matrix buffer",
    )
    HEADER.write_text(text, encoding="utf-8")


def prepare_cmake() -> None:
    text = CMAKE.read_text(encoding="utf-8")
    text = replace_once(
        text,
        'set(PEPEPOW_CUDA_THREADS "128" CACHE STRING "CUDA threads per Header80 search block")\n',
        'set(PEPEPOW_CUDA_THREADS "128" CACHE STRING "CUDA threads per Header80 search block")\n'
        'set(PEPEPOW_CUDA_MIN_BLOCKS "1" CACHE STRING "Minimum resident blocks per SM launch hint")\n'
        'option(PEPEPOW_CUDA_SCALED_MATRIX "Use exact scaled-matrix constant cache" ON)\n'
        'set(PEPEPOW_CUDA_BYTE_UNROLL "1" CACHE STRING "HooHash byte-loop unroll factor")\n',
        "v0.5.0 CUDA options",
    )
    text = replace_once(
        text,
        '    if(NOT PEPEPOW_CUDA_THREADS MATCHES "^(64|128|256)$")\n'
        '        message(FATAL_ERROR "PEPEPOW_CUDA_THREADS must be 64, 128 or 256")\n'
        '    endif()\n',
        '    if(NOT PEPEPOW_CUDA_THREADS MATCHES "^(64|128|256)$")\n'
        '        message(FATAL_ERROR "PEPEPOW_CUDA_THREADS must be 64, 128 or 256")\n'
        '    endif()\n'
        '    if(NOT PEPEPOW_CUDA_MIN_BLOCKS MATCHES "^[1-4]$")\n'
        '        message(FATAL_ERROR "PEPEPOW_CUDA_MIN_BLOCKS must be 1 through 4")\n'
        '    endif()\n'
        '    if(NOT PEPEPOW_CUDA_BYTE_UNROLL MATCHES "^(1|2|4)$")\n'
        '        message(FATAL_ERROR "PEPEPOW_CUDA_BYTE_UNROLL must be 1, 2 or 4")\n'
        '    endif()\n',
        "v0.5.0 option validation",
    )
    text = replace_once(
        text,
        '        src/cuda/header80_backend.cu\n',
        '        src/cuda/header80_backend_v050.cu\n',
        "word-pipeline backend selection",
    )
    text = replace_once(
        text,
        '    target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_THREADS=${PEPEPOW_CUDA_THREADS})\n',
        '    target_compile_definitions(pepepow_cuda PRIVATE\n'
        '        PEPEPOW_CUDA_THREADS=${PEPEPOW_CUDA_THREADS}\n'
        '        PEPEPOW_CUDA_MIN_BLOCKS=${PEPEPOW_CUDA_MIN_BLOCKS}\n'
        '        PEPEPOW_CUDA_BYTE_UNROLL=${PEPEPOW_CUDA_BYTE_UNROLL})\n'
        '    if(PEPEPOW_CUDA_SCALED_MATRIX)\n'
        '        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_SCALED_MATRIX=1)\n'
        '    else()\n'
        '        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_SCALED_MATRIX=0)\n'
        '    endif()\n',
        "v0.5.0 compile definitions",
    )
    CMAKE.write_text(text, encoding="utf-8")


def prepare_validation() -> None:
    text = VALIDATION.read_text(encoding="utf-8")
    text = replace_once(
        text,
        '        std::cout << "PASS: canonical header80 CPU/CUDA hashes match\\n";\n',
        '        std::cout << "PASS: canonical header80 CPU/CUDA hashes match\\n";\n'
        '        std::uint32_t deterministic_nonce = 0x243f6a88U;\n'
        '        for (std::size_t sample = 0; sample < 512U; ++sample) {\n'
        '            deterministic_nonce = deterministic_nonce * 1664525U + 1013904223U;\n'
        '            auto job = make_validation_job();\n'
        '            job.nonce = deterministic_nonce;\n'
        '            const auto header = pepepow::build_header80(job);\n'
        '            const auto cpu_hash = pepepow::crypto::calculate_header80_pow(header);\n'
        '            const auto gpu_candidate = backend.search(\n'
        '                job, pepepow::SearchRange{deterministic_nonce, 1U}, maximum_target);\n'
        '            if (!gpu_candidate.has_value() || gpu_candidate->nonce != deterministic_nonce ||\n'
        '                gpu_candidate->hash != cpu_hash) {\n'
        '                throw std::runtime_error("word-pipeline CPU/CUDA sample mismatch");\n'
        '            }\n'
        '        }\n'
        '        std::cout << "PASS: 512 word-pipeline CPU/CUDA samples match\\n";\n',
        "word-pipeline deterministic validation",
    )
    VALIDATION.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    apply_v040_profile()
    prepare_main()
    prepare_header()
    prepare_cmake()
    prepare_validation()

    required = {
        MAIN: (
            "PepeW Warp Pipeline Edition",
            "https://t.me/pepepow_ru",
            "word_pipeline=1",
            "scaled_matrix=autotune",
        ),
        HEADER: ("device_matrix_",),
        CMAKE: (
            "header80_backend_v050.cu",
            "PEPEPOW_CUDA_SCALED_MATRIX",
            "PEPEPOW_CUDA_MIN_BLOCKS",
            "PEPEPOW_CUDA_BYTE_UNROLL",
        ),
        VALIDATION: ("PASS: 512 word-pipeline CPU/CUDA samples match",),
    }
    for path, markers in required.items():
        value = path.read_text(encoding="utf-8")
        for marker in markers:
            if marker not in value:
                raise SystemExit(f"v0.5.0 source missing marker in {path.name}: {marker}")

    print("PASS: v0.5.0 word-pipeline source profile applied")
