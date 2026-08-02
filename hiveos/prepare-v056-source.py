#!/usr/bin/env python3
"""Apply the v0.5.6 cold-path/occupancy CUDA experiment.

Nsight Compute on the validated v0.5.4 lookup-finite-mono64 kernel showed:
* 79.2% FP64-pipe utilization and only 3.15% memory throughput;
* 28.15 short-scoreboard stall cycles per issued instruction (76.4%);
* 87 registers/thread, 41.7% theoretical and 34.9% achieved occupancy;
* only 8.38 active threads/warp because the rare nonlinear path diverges.

v0.5.6 keeps every consensus-preserving v0.5.4 transformation and autotunes:
1. hot-path-first branch layout;
2. outlining of rare transcendental work at leaf/nonlinear/safe levels;
3. launch-bounds removal so --maxrregcount is no longer overridden;
4. real register caps and launch geometry after every candidate passes
   CPU/CUDA consensus validation.
"""
from __future__ import annotations

from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
VERSION_FILE = ROOT / "VERSION"
MAIN = ROOT / "native/src/app/main.cpp"
CMAKE = ROOT / "native/CMakeLists.txt"
H_RUN = ROOT / "hiveos/h-run.sh"
V054 = ROOT / "native/src/cuda/header80_backend_v054.cu"
V056 = ROOT / "native/src/cuda/header80_backend_v056.cu"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"v0.5.6 source preparation failed: {label}")
    return text.replace(old, new, 1)


def require(path: Path, markers: list[str]) -> None:
    text = path.read_text(encoding="utf-8")
    for marker in markers:
        if marker not in text:
            raise SystemExit(f"v0.5.6 requires v0.5.4 base marker in {path.name}: {marker}")


def prepare_version() -> None:
    VERSION_FILE.write_text("0.5.6-PR\n", encoding="utf-8")


def prepare_main() -> None:
    text = MAIN.read_text(encoding="utf-8")
    text = replace_once(
        text,
        'return std::string("PepeW Lookup Split Edition ") + PEPEPOW_VERSION +',
        'return std::string("PepeW Cold Path Edition ") + PEPEPOW_VERSION +',
        "build identity",
    )
    text = replace_once(
        text,
        '                  "pipeline=autotune exact_bit_conversions=1 "\n'
        '                  "bit_sw_fraction=1 scaled_nibble_table=autotune "\n'
        '                  "assume_finite=autotune hashmod_hoist=1 "\n'
        '                  "scaled_matrix=1 upload_cache=1 prefer_l1=1");',
        '                  "pipeline=monolithic exact_bit_conversions=1 "\n'
        '                  "bit_sw_fraction=1 scaled_nibble_table=1 "\n'
        '                  "assume_finite=1 cold_nonlinear=autotune "\n'
        '                  "hot_branch_first=autotune launch_bounds=autotune "\n'
        '                  "register_cap=autotune prefer_l1=1");',
        "v0.5.6 runtime markers",
    )
    MAIN.write_text(text, encoding="utf-8")


def prepare_cmake() -> None:
    text = CMAKE.read_text(encoding="utf-8")
    option_marker = 'option(PEPEPOW_CUDA_ASSUME_FINITE "Skip unreachable non-finite retry loop for bounded HooHash inputs" OFF)\n'
    text = replace_once(
        text,
        option_marker,
        option_marker
        + 'set(PEPEPOW_CUDA_COLD_NONLINEAR_MODE "0" CACHE STRING "0=inline, 1=outline transcendental leaves, 2=outline nonlinear selector, 3=outline safe nonlinear path")\n'
        + 'option(PEPEPOW_CUDA_HOT_BRANCH_FIRST "Lay out the common scaled-lookup branch before the rare nonlinear branch" OFF)\n'
        + 'option(PEPEPOW_CUDA_USE_LAUNCH_BOUNDS "Use Header80 launch_bounds; disable to make maxrregcount effective" ON)\n',
        "v0.5.6 CUDA options",
    )
    text = replace_once(
        text,
        '        src/cuda/header80_backend_v054.cu\n',
        '        src/cuda/header80_backend_v056.cu\n',
        "v0.5.6 backend selection",
    )
    validation_marker = '''    if(NOT PEPEPOW_CUDA_BYTE_UNROLL MATCHES "^(1|2|4)$")
        message(FATAL_ERROR "PEPEPOW_CUDA_BYTE_UNROLL must be 1, 2 or 4")
    endif()
'''
    text = replace_once(
        text,
        validation_marker,
        validation_marker
        + '    if(NOT PEPEPOW_CUDA_COLD_NONLINEAR_MODE MATCHES "^[0-3]$")\n'
        + '        message(FATAL_ERROR "PEPEPOW_CUDA_COLD_NONLINEAR_MODE must be 0, 1, 2 or 3")\n'
        + '    endif()\n',
        "cold mode validation",
    )
    finite_block = '''    if(PEPEPOW_CUDA_ASSUME_FINITE)
        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_ASSUME_FINITE=1)
    else()
        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_ASSUME_FINITE=0)
    endif()
'''
    text = replace_once(
        text,
        finite_block,
        finite_block
        + '    target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_COLD_NONLINEAR_MODE=${PEPEPOW_CUDA_COLD_NONLINEAR_MODE})\n'
        + '    if(PEPEPOW_CUDA_HOT_BRANCH_FIRST)\n'
        + '        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_HOT_BRANCH_FIRST=1)\n'
        + '    else()\n'
        + '        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_HOT_BRANCH_FIRST=0)\n'
        + '    endif()\n'
        + '    if(PEPEPOW_CUDA_USE_LAUNCH_BOUNDS)\n'
        + '        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_USE_LAUNCH_BOUNDS=1)\n'
        + '    else()\n'
        + '        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_USE_LAUNCH_BOUNDS=0)\n'
        + '    endif()\n',
        "v0.5.6 compile definitions",
    )
    CMAKE.write_text(text, encoding="utf-8")


def prepare_hive_run() -> None:
    text = H_RUN.read_text(encoding="utf-8")
    text = text.replace(
        "AUTOTUNED_PIPELINE EXACT_BIT_CONVERSIONS BIT_SW_FRACTION SCALED_NIBBLE_TABLE ASSUME_FINITE HASHMOD_HOIST PREFER_L1",
        "AUTOTUNED_PIPELINE EXACT_BIT_CONVERSIONS BIT_SW_FRACTION SCALED_NIBBLE_TABLE ASSUME_FINITE COLD_NONLINEAR_MODE HOT_BRANCH_FIRST USE_LAUNCH_BOUNDS MAX_REGISTERS HASHMOD_HOIST PREFER_L1",
    )
    text = text.replace(
        "autotuned monolithic/split pipeline; exact bit conversions; direct bit fraction(sum/1024); optional cell-major scaled-nibble lookup; finite-domain nonlinear fast path; hash-mod conversion hoist; PreferL1; persistent buffers; 524288 runtime batch",
        "monolithic lookup/finite pipeline; rare nonlinear cold-path outlining; hot branch layout; real register-cap autotune without launch-bounds override; exact bit conversions; PreferL1; persistent buffers; 524288 runtime batch",
    )
    H_RUN.write_text(text, encoding="utf-8")


def prepare_cuda() -> None:
    text = V054.read_text(encoding="utf-8")
    text = replace_once(
        text,
        '#ifndef PEPEPOW_CUDA_ASSUME_FINITE\n#define PEPEPOW_CUDA_ASSUME_FINITE 0\n#endif\n',
        '#ifndef PEPEPOW_CUDA_ASSUME_FINITE\n#define PEPEPOW_CUDA_ASSUME_FINITE 0\n#endif\n'
        '#ifndef PEPEPOW_CUDA_COLD_NONLINEAR_MODE\n#define PEPEPOW_CUDA_COLD_NONLINEAR_MODE 0\n#endif\n'
        '#ifndef PEPEPOW_CUDA_HOT_BRANCH_FIRST\n#define PEPEPOW_CUDA_HOT_BRANCH_FIRST 0\n#endif\n'
        '#ifndef PEPEPOW_CUDA_USE_LAUNCH_BOUNDS\n#define PEPEPOW_CUDA_USE_LAUNCH_BOUNDS 1\n#endif\n'
        '#if PEPEPOW_CUDA_USE_LAUNCH_BOUNDS\n'
        '#define PEPEPOW_HEADER80_LAUNCH_BOUNDS __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)\n'
        '#else\n'
        '#define PEPEPOW_HEADER80_LAUNCH_BOUNDS\n'
        '#endif\n',
        "v0.5.6 CUDA macros",
    )

    old_nonlinear = '''__device__ __forceinline__ double nonlinear(double x) {
    const double scaled = x * kTransformMultiplier;
    const double one_base = scaled / 8.0;
    const double one = positive_fraction(one_base);
#if PEPEPOW_CUDA_DERIVE_TWO
    const double doubled_one = one + one;
    const double two = doubled_one >= 1.0 ? doubled_one - 1.0 : doubled_one;
#else
    const double two = positive_fraction(scaled / 4.0);
#endif
    double y;
    if (two < 0.25) y = x + (1.0 + two);
    else if (two < 0.50) y = x - (1.0 + two);
    else if (two < 0.75) y = x * (1.0 + two);
    else y = x / (1.0 + two);
    if (one < 0.33) {
        double sine, cosine;
        sincos(y, &sine, &cosine);
        return exp(sine + cosine);
    }
    if (one < 0.66) {
        if (y == kPi / 2.0 || y == 3.0 * kPi / 2.0) return 0.0;
        const double sine = sin(y);
        return sine * sine;
    }
    return 1.0 / sqrt(fabs(y) + 1.0);
}

__device__ __forceinline__ double safe_nonlinear(double x) {
#if PEPEPOW_CUDA_ASSUME_FINITE
    // HooHash V110 bounds x to roughly 6.5e16: matrix <= 1e6,
    // hash_mod <= UINT32_MAX, nibble <= 15 and nonce_mod <= 255.
    // All selector transforms remain finite; exp receives sin+cos in
    // [-sqrt(2), sqrt(2)]. Therefore the retry loop is unreachable for valid
    // consensus inputs. The guarded reference path remains available to the
    // autotuner and every candidate is CPU/CUDA validated.
    return nonlinear(x);
#else
    double rounds = 1.0;
    double out = nonlinear(x);
    while (isnan(out) || isinf(out)) {
        x *= 0.1;
        if (x <= 1e-13) return 0.0;
        rounds += 1.0;
        out = nonlinear(x);
    }
    return out * rounds;
#endif
}'''

    new_nonlinear = r'''#if PEPEPOW_CUDA_COLD_NONLINEAR_MODE == 1
#define PEPEPOW_COLD_LEAF_ATTR __noinline__
#else
#define PEPEPOW_COLD_LEAF_ATTR __forceinline__
#endif
#if PEPEPOW_CUDA_COLD_NONLINEAR_MODE == 2
#define PEPEPOW_NONLINEAR_ATTR __noinline__
#else
#define PEPEPOW_NONLINEAR_ATTR __forceinline__
#endif
#if PEPEPOW_CUDA_COLD_NONLINEAR_MODE == 3
#define PEPEPOW_SAFE_NONLINEAR_ATTR __noinline__
#else
#define PEPEPOW_SAFE_NONLINEAR_ATTR __forceinline__
#endif

__device__ PEPEPOW_COLD_LEAF_ATTR double nonlinear_medium(double y) {
    double sine, cosine;
    sincos(y, &sine, &cosine);
    return exp(sine + cosine);
}

__device__ PEPEPOW_COLD_LEAF_ATTR double nonlinear_intermediate(double y) {
    if (y == kPi / 2.0 || y == 3.0 * kPi / 2.0) return 0.0;
    const double sine = sin(y);
    return sine * sine;
}

__device__ PEPEPOW_COLD_LEAF_ATTR double nonlinear_high(double y) {
    return 1.0 / sqrt(fabs(y) + 1.0);
}

__device__ PEPEPOW_NONLINEAR_ATTR double nonlinear(double x) {
    const double scaled = x * kTransformMultiplier;
    const double one_base = scaled / 8.0;
    const double one = positive_fraction(one_base);
#if PEPEPOW_CUDA_DERIVE_TWO
    const double doubled_one = one + one;
    const double two = doubled_one >= 1.0 ? doubled_one - 1.0 : doubled_one;
#else
    const double two = positive_fraction(scaled / 4.0);
#endif
    double y;
    if (two < 0.25) y = x + (1.0 + two);
    else if (two < 0.50) y = x - (1.0 + two);
    else if (two < 0.75) y = x * (1.0 + two);
    else y = x / (1.0 + two);
    if (one < 0.33) return nonlinear_medium(y);
    if (one < 0.66) return nonlinear_intermediate(y);
    return nonlinear_high(y);
}

__device__ PEPEPOW_SAFE_NONLINEAR_ATTR double safe_nonlinear(double x) {
#if PEPEPOW_CUDA_ASSUME_FINITE
    return nonlinear(x);
#else
    double rounds = 1.0;
    double out = nonlinear(x);
    while (isnan(out) || isinf(out)) {
        x *= 0.1;
        if (x <= 1e-13) return 0.0;
        rounds += 1.0;
        out = nonlinear(x);
    }
    return out * rounds;
#endif
}'''
    text = replace_once(text, old_nonlinear, new_nonlinear, "cold nonlinear functions")

    old_accumulate = '''    if (sw <= 0.02) {
        if (nibble != 0U) {
            const double cell = matrix[cell_index];
            const double x = cell * hash_mod * value + nonce_mod;
            sum += safe_nonlinear(x) * value * 1234.0;
        }
    } else {
#if PEPEPOW_CUDA_SCALED_NIBBLE_TABLE
        // Cell-major layout makes the 32 lanes read from one contiguous
        // 128-byte group. The table value is computed on the host as exactly
        // (matrix[cell] * 0.0001) * nibble, preserving operation order and
        // rounding while replacing a hot FP64 multiply with a cached load.
        sum += __ldg(scaled_nibble_table +
                     static_cast<std::size_t>(cell_index) * 16U + nibble);
#elif PEPEPOW_CUDA_SCALED_MATRIX
        sum += kHeader80ScaledMatrix[cell_index] * value;
#else
        sum += matrix[cell_index] * 0.0001 * value;
#endif
    }
'''
    new_accumulate = r'''#if PEPEPOW_CUDA_HOT_BRANCH_FIRST
    if (sw > 0.02) {
#if PEPEPOW_CUDA_SCALED_NIBBLE_TABLE
        sum += __ldg(scaled_nibble_table +
                     static_cast<std::size_t>(cell_index) * 16U + nibble);
#elif PEPEPOW_CUDA_SCALED_MATRIX
        sum += kHeader80ScaledMatrix[cell_index] * value;
#else
        sum += matrix[cell_index] * 0.0001 * value;
#endif
    } else if (nibble != 0U) {
        const double cell = matrix[cell_index];
        const double x = cell * hash_mod * value + nonce_mod;
        sum += safe_nonlinear(x) * value * 1234.0;
    }
#else
    if (sw <= 0.02) {
        if (nibble != 0U) {
            const double cell = matrix[cell_index];
            const double x = cell * hash_mod * value + nonce_mod;
            sum += safe_nonlinear(x) * value * 1234.0;
        }
    } else {
#if PEPEPOW_CUDA_SCALED_NIBBLE_TABLE
        sum += __ldg(scaled_nibble_table +
                     static_cast<std::size_t>(cell_index) * 16U + nibble);
#elif PEPEPOW_CUDA_SCALED_MATRIX
        sum += kHeader80ScaledMatrix[cell_index] * value;
#else
        sum += matrix[cell_index] * 0.0001 * value;
#endif
    }
#endif
'''
    text = replace_once(text, old_accumulate, new_accumulate, "hot branch layout")
    text = text.replace(
        '__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)\n',
        '__global__ PEPEPOW_HEADER80_LAUNCH_BOUNDS\n',
    )
    if text.count('__global__ PEPEPOW_HEADER80_LAUNCH_BOUNDS') != 4:
        raise SystemExit("v0.5.6 source preparation failed: launch-bounds replacement")
    V056.write_text(text, encoding="utf-8")


def verify() -> None:
    checks = {
        VERSION_FILE: ["0.5.6-PR"],
        MAIN: ["PepeW Cold Path Edition", "cold_nonlinear=autotune"],
        CMAKE: ["header80_backend_v056.cu", "PEPEPOW_CUDA_COLD_NONLINEAR_MODE", "PEPEPOW_CUDA_USE_LAUNCH_BOUNDS"],
        V056: ["nonlinear_medium", "PEPEPOW_SAFE_NONLINEAR_ATTR", "PEPEPOW_CUDA_HOT_BRANCH_FIRST", "PEPEPOW_HEADER80_LAUNCH_BOUNDS"],
        H_RUN: ["COLD_NONLINEAR_MODE", "real register-cap autotune"],
    }
    for path, markers in checks.items():
        require(path, markers)


def main() -> None:
    require(V054, ["PEPEPOW_CUDA_SCALED_NIBBLE_TABLE", "PEPEPOW_CUDA_ASSUME_FINITE", "header80_pow_kernel"])
    prepare_version()
    prepare_main()
    prepare_cmake()
    prepare_hive_run()
    prepare_cuda()
    verify()
    print("PASS: v0.5.6 cold-path/occupancy source profile applied")


if __name__ == "__main__":
    main()
