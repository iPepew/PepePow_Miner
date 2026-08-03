#!/usr/bin/env python3
from __future__ import annotations

import subprocess
import sys
from pathlib import Path


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if old not in text:
        raise SystemExit(f"ERROR: {label} anchor not found")
    return text.replace(old, new, 1)


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} BEAUTIFUL_PATCHER SOURCE_ROOT", file=sys.stderr)
        return 2

    beautiful = Path(sys.argv[1]).resolve()
    root = Path(sys.argv[2]).resolve()
    subprocess.run([sys.executable, str(beautiful), str(root)], check=True)

    main_cpp = root / "native/src/app/main.cpp"
    config = root / "hiveos/h-config.sh"
    run = root / "hiveos/h-run.sh"

    text = main_cpp.read_text(encoding="utf-8")
    old_chunk = '''        // 262K keeps the optimized GPU path saturated while reducing stale-job
        // exposure to roughly half of the earlier 524K validation batch.
        constexpr std::uint64_t chunk_size = 262144;'''
    new_chunk = '''        // Production-tuned runtime batch. A larger batch amortizes host launch,
        // job preparation and status overhead while remaining below one second
        // on the verified RTX 3080 service768 profile.
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

    banner_anchor = '            << kCyan << " Engine    : " << kReset << "service768 / CUDA sm_86\\n"\n'
    if banner_anchor in text:
        text = text.replace(
            banner_anchor,
            banner_anchor + '            << kCyan << " Live mode : " << kReset << "Turbo / batch 1048576\\n"\n',
            1,
        )
    main_cpp.write_text(text, encoding="utf-8")

    config_text = config.read_text(encoding="utf-8")
    old_args = '''args=("-o" "stratum+tcp://127.0.0.1:${proxy_port}" "-u" "${user}" "-p" "${pass}"
      "--diagnostic" "--diagnostic-log" "${diagnostic_log}")'''
    new_args = '''args=("-o" "stratum+tcp://127.0.0.1:${proxy_port}" "-u" "${user}" "-p" "${pass}")

# Full per-job diagnostics are intentionally disabled in production because
# they add disk and console overhead. Enable explicitly with PEPEW_DIAGNOSTIC=1.
if [[ "${PEPEW_DIAGNOSTIC:-0}" == "1" ]]; then
  args+=("--diagnostic" "--diagnostic-log" "${diagnostic_log}")
fi'''
    config_text = replace_once(config_text, old_args, new_args, "production diagnostics")
    config_text = config_text.replace(
        'echo "Diagnostic mode: enabled"',
        'echo "Diagnostic mode: ${PEPEW_DIAGNOSTIC:-0}"',
    )
    config.write_text(config_text, encoding="utf-8")

    run_text = run.read_text(encoding="utf-8")
    locale_anchor = 'export LC_ALL="${LC_ALL:-C.UTF-8}"\n'
    turbo_env = (
        'export PEPEW_BATCH_SIZE="${PEPEW_BATCH_SIZE:-1048576}"\n'
        'export PEPEW_DIAGNOSTIC="${PEPEW_DIAGNOSTIC:-0}"\n'
    )
    if turbo_env not in run_text:
        if locale_anchor not in run_text:
            raise SystemExit("ERROR: locale anchor not found")
        run_text = run_text.replace(locale_anchor, locale_anchor + turbo_env, 1)
    run_text = run_text.replace(
        'echo "Optimizations: service768 block-compacted cold path; exact FP64 selectors; scaled-nibble table; GPU target filter; CPU share verification"',
        'echo "Optimizations: service768; turbo batch=${PEPEW_BATCH_SIZE}; production diagnostics=${PEPEW_DIAGNOSTIC}; exact FP64; CPU share verification"',
    )
    run.write_text(run_text, encoding="utf-8")

    print("TURBO_SOURCE_PATCH=PASS")
    print("PEPEW_BATCH_SIZE=1048576")
    print("PEPEW_DIAGNOSTIC=0")
    print("TARGET_2MH=REQUIRES_LIVE_RECHECK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
