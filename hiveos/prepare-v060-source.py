#!/usr/bin/env python3
"""Apply the v0.6.0 exact HooHash state-predicate CUDA experiment.

Prior RTX 3080 experiments established that ILP, cold-path outlining, register
caps, larger blocks and higher nominal occupancy do not improve the validated
v0.5.4 kernel. v0.6.0 therefore targets the serial dependency executed after
every matrix cell:

    sum -> fraction(sum / 1024) -> compare with 0.02 -> next cell

The HooHash algorithm only consumes the comparison result on the next cell.
This profile tests four consensus-gated representations:

0. original v0.5.4 double fraction state;
1. boolean state produced by the validated fraction helper;
2. boolean state produced by a defensive exact IEEE-754 predicate;
3. boolean state produced by the same exact predicate under the already proven
   positive-finite HooHash domain, without defensive fallback branches.
"""
from __future__ import annotations

from pathlib import Path
import runpy

ROOT = Path(__file__).resolve().parents[1]
VERSION_FILE = ROOT / "VERSION"
MAIN = ROOT / "native/src/app/main.cpp"
CMAKE = ROOT / "native/CMakeLists.txt"
H_RUN = ROOT / "hiveos/h-run.sh"
VALIDATION = ROOT / "native/tests/cuda_header80_validation.cpp"
V054 = ROOT / "native/src/cuda/header80_backend_v054.cu"
V060 = ROOT / "native/src/cuda/header80_backend_v060.cu"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"v0.6.0 source preparation failed: {label}")
    return text.replace(old, new, 1)


def apply_v054_profile() -> None:
    runpy.run_path(str(ROOT / "hiveos/prepare-v054-source.py"), run_name="__main__")


def prepare_version() -> None:
    VERSION_FILE.write_text("0.6.0-PR\n", encoding="utf-8")


def prepare_main() -> None:
    text = MAIN.read_text(encoding="utf-8")
    text = replace_once(
        text,
        'return std::string("PepeW Lookup Split Edition ") + PEPEPOW_VERSION +',
        'return std::string("PepeW Critical Path Edition ") + PEPEPOW_VERSION +',
        "build identity",
    )
    text = replace_once(
        text,
        '                  "pipeline=autotune exact_bit_conversions=1 "\n'
        '                  "bit_sw_fraction=1 scaled_nibble_table=autotune "\n'
        '                  "assume_finite=autotune hashmod_hoist=1 "\n'
        '                  "scaled_matrix=1 upload_cache=1 prefer_l1=1");',
        '                  "pipeline=autotune exact_bit_conversions=1 "\n'
        '                  "scaled_nibble_table=1 assume_finite=1 "\n'
        '                  "sw_state_mode=autotune exact_threshold=1 "\n'
        '                  "scaled_matrix=1 upload_cache=1 prefer_l1=1");',
        "v0.6.0 runtime markers",
    )
    MAIN.write_text(text, encoding="utf-8")


def prepare_cmake() -> None:
    text = CMAKE.read_text(encoding="utf-8")
    option_marker = (
        'option(PEPEPOW_CUDA_ASSUME_FINITE '
        '"Skip unreachable non-finite retry loop for bounded HooHash inputs" OFF)\n'
    )
    text = replace_once(
        text,
        option_marker,
        option_marker
        + 'set(PEPEPOW_CUDA_SW_STATE_MODE "0" CACHE STRING '
        '"0=double fraction, 1=bool via fraction helper, '
        '2=defensive exact predicate, 3=positive-finite exact predicate")\n',
        "state mode option",
    )
    text = replace_once(
        text,
        "        src/cuda/header80_backend_v054.cu\n",
        "        src/cuda/header80_backend_v060.cu\n",
        "v0.6.0 backend selection",
    )
    validation_marker = '''    if(NOT PEPEPOW_CUDA_BYTE_UNROLL MATCHES "^(1|2|4)$")
        message(FATAL_ERROR "PEPEPOW_CUDA_BYTE_UNROLL must be 1, 2 or 4")
    endif()
'''
    text = replace_once(
        text,
        validation_marker,
        validation_marker
        + '    if(NOT PEPEPOW_CUDA_SW_STATE_MODE MATCHES "^[0-3]$")\n'
        + '        message(FATAL_ERROR "PEPEPOW_CUDA_SW_STATE_MODE must be 0, 1, 2 or 3")\n'
        + '    endif()\n',
        "state mode validation",
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
        + '    target_compile_definitions(pepepow_cuda PRIVATE '
        + 'PEPEPOW_CUDA_SW_STATE_MODE=${PEPEPOW_CUDA_SW_STATE_MODE})\n',
        "state mode compile definition",
    )
    CMAKE.write_text(text, encoding="utf-8")


def prepare_hive_run() -> None:
    text = H_RUN.read_text(encoding="utf-8")
    text = text.replace(
        "AUTOTUNED_PIPELINE EXACT_BIT_CONVERSIONS BIT_SW_FRACTION "
        "SCALED_NIBBLE_TABLE ASSUME_FINITE HASHMOD_HOIST PREFER_L1",
        "AUTOTUNED_PIPELINE EXACT_BIT_CONVERSIONS BIT_SW_FRACTION "
        "SCALED_NIBBLE_TABLE ASSUME_FINITE SW_STATE_MODE HASHMOD_HOIST PREFER_L1",
    )
    text = text.replace(
        "autotuned monolithic/split pipeline; exact bit conversions; "
        "direct bit fraction(sum/1024); optional cell-major scaled-nibble lookup; "
        "finite-domain nonlinear fast path; hash-mod conversion hoist; PreferL1; "
        "persistent buffers; 524288 runtime batch",
        "critical-path state-predicate autotune; exact bit conversions; "
        "cell-major scaled-nibble lookup; finite-domain nonlinear fast path; "
        "hash-mod conversion hoist; PreferL1; persistent buffers; 524288 runtime batch",
    )
    H_RUN.write_text(text, encoding="utf-8")


def prepare_validation() -> None:
    text = VALIDATION.read_text(encoding="utf-8")
    text = text.replace("sample < 16384U", "sample < 32768U")
    text = text.replace(
        "PASS: 16384 lookup-split CPU/CUDA samples match",
        "PASS: 32768 critical-path CPU/CUDA samples match",
    )
    if (
        "sample < 32768U" not in text
        or "PASS: 32768 critical-path CPU/CUDA samples match" not in text
    ):
        raise SystemExit("v0.6.0 source preparation failed: validation expansion")
    VALIDATION.write_text(text, encoding="utf-8")


def prepare_cuda() -> None:
    text = V054.read_text(encoding="utf-8")

    text = replace_once(
        text,
        "#ifndef PEPEPOW_CUDA_ASSUME_FINITE\n"
        "#define PEPEPOW_CUDA_ASSUME_FINITE 0\n"
        "#endif\n",
        "#ifndef PEPEPOW_CUDA_ASSUME_FINITE\n"
        "#define PEPEPOW_CUDA_ASSUME_FINITE 0\n"
        "#endif\n"
        "#ifndef PEPEPOW_CUDA_SW_STATE_MODE\n"
        "#define PEPEPOW_CUDA_SW_STATE_MODE 0\n"
        "#endif\n",
        "state mode CUDA macro",
    )

    helper_marker = (
        "__device__ __forceinline__ std::uint64_t "
        "positive_double_to_u64_rz(double value) {"
    )
    exact_helpers = r'''__device__ __forceinline__ bool
positive_fraction_div1024_le_002_exact(double value) {
    const std::uint64_t bits =
        static_cast<std::uint64_t>(__double_as_longlong(value));
    constexpr std::uint64_t kSignMask = 0x8000000000000000ULL;
    constexpr std::uint64_t kScaledThresholdBits = 0x40347ae147ae147bULL;
    constexpr std::uint64_t kThresholdSignificand = 5764607523034235ULL;

    const unsigned int exponent =
        static_cast<unsigned int>((bits >> 52U) & 0x7ffULL);
    if ((bits & kSignMask) != 0ULL || exponent == 0x7ffU) {
        return positive_fraction_div1024_bits(value) <= 0.02;
    }
    if (bits <= kScaledThresholdBits) return true;
    if (exponent < 1033U) return false;

    const unsigned int integer_bits = exponent - 1033U;
    if (integer_bits >= 52U) return true;
    const unsigned int fractional_width = 52U - integer_bits;
    const std::uint64_t remainder_mask =
        (1ULL << fractional_width) - 1ULL;
    const std::uint64_t remainder = bits & remainder_mask;
    return (remainder << (58U - fractional_width)) <=
           kThresholdSignificand;
}

__device__ __forceinline__ bool
positive_fraction_div1024_le_002_finite(double value) {
    const std::uint64_t bits =
        static_cast<std::uint64_t>(__double_as_longlong(value));
    constexpr std::uint64_t kScaledThresholdBits = 0x40347ae147ae147bULL;
    constexpr std::uint64_t kThresholdSignificand = 5764607523034235ULL;

    if (bits <= kScaledThresholdBits) return true;
    const unsigned int exponent =
        static_cast<unsigned int>((bits >> 52U) & 0x7ffULL);
    if (exponent < 1033U) return false;

    const unsigned int integer_bits = exponent - 1033U;
    if (integer_bits >= 52U) return true;
    const unsigned int fractional_width = 52U - integer_bits;
    const std::uint64_t remainder =
        bits & ((1ULL << fractional_width) - 1ULL);
    return (remainder << (58U - fractional_width)) <=
           kThresholdSignificand;
}

#if PEPEPOW_CUDA_SW_STATE_MODE == 0
using HooHashSwState = double;
__device__ __forceinline__ HooHashSwState initial_sw_state() { return 0.0; }
__device__ __forceinline__ bool sw_state_is_cold(HooHashSwState state) {
    return state <= 0.02;
}
__device__ __forceinline__ void update_sw_state(
    HooHashSwState& state, double sum) {
    state = positive_fraction_div1024_bits(sum);
}
#elif PEPEPOW_CUDA_SW_STATE_MODE == 1
using HooHashSwState = bool;
__device__ __forceinline__ HooHashSwState initial_sw_state() { return true; }
__device__ __forceinline__ bool sw_state_is_cold(HooHashSwState state) {
    return state;
}
__device__ __forceinline__ void update_sw_state(
    HooHashSwState& state, double sum) {
    state = positive_fraction_div1024_bits(sum) <= 0.02;
}
#elif PEPEPOW_CUDA_SW_STATE_MODE == 2
using HooHashSwState = bool;
__device__ __forceinline__ HooHashSwState initial_sw_state() { return true; }
__device__ __forceinline__ bool sw_state_is_cold(HooHashSwState state) {
    return state;
}
__device__ __forceinline__ void update_sw_state(
    HooHashSwState& state, double sum) {
    state = positive_fraction_div1024_le_002_exact(sum);
}
#else
using HooHashSwState = bool;
__device__ __forceinline__ HooHashSwState initial_sw_state() { return true; }
__device__ __forceinline__ bool sw_state_is_cold(HooHashSwState state) {
    return state;
}
__device__ __forceinline__ void update_sw_state(
    HooHashSwState& state, double sum) {
    state = positive_fraction_div1024_le_002_finite(sum);
}
#endif

'''
    text = replace_once(
        text,
        helper_marker,
        exact_helpers + helper_marker,
        "exact predicate helpers",
    )

    if text.count("double& sw") < 2:
        raise SystemExit("v0.6.0 source preparation failed: sw reference markers")
    text = text.replace("double& sw", "HooHashSwState& sw")
    text = replace_once(
        text,
        "    if (sw <= 0.02) {",
        "    if (sw_state_is_cold(sw)) {",
        "state predicate use",
    )
    text = replace_once(
        text,
        "    sw = positive_fraction_div1024_bits(sum);",
        "    update_sw_state(sw, sum);",
        "state predicate update",
    )
    text = replace_once(
        text,
        "    double sw = 0.0;",
        "    HooHashSwState sw = initial_sw_state();",
        "state initialization",
    )

    for marker in (
        "PEPEPOW_CUDA_SW_STATE_MODE",
        "positive_fraction_div1024_le_002_exact",
        "positive_fraction_div1024_le_002_finite",
        "HooHashSwState",
        "sw_state_is_cold",
        "update_sw_state",
    ):
        if marker not in text:
            raise SystemExit(f"v0.6.0 CUDA source missing marker: {marker}")
    V060.write_text(text, encoding="utf-8")


def already_prepared() -> bool:
    return (
        V060.exists()
        and "PepeW Critical Path Edition" in MAIN.read_text(encoding="utf-8")
        and "header80_backend_v060.cu" in CMAKE.read_text(encoding="utf-8")
    )


if __name__ == "__main__":
    if not already_prepared():
        apply_v054_profile()
        prepare_version()
        prepare_main()
        prepare_cmake()
        prepare_hive_run()
        prepare_validation()
        prepare_cuda()

    required = {
        MAIN: ("PepeW Critical Path Edition", "sw_state_mode=autotune"),
        CMAKE: ("header80_backend_v060.cu", "PEPEPOW_CUDA_SW_STATE_MODE"),
        VALIDATION: ("PASS: 32768 critical-path CPU/CUDA samples match",),
        V060: (
            "positive_fraction_div1024_le_002_exact",
            "positive_fraction_div1024_le_002_finite",
            "HooHashSwState",
        ),
    }
    for path, markers in required.items():
        value = path.read_text(encoding="utf-8")
        for marker in markers:
            if marker not in value:
                raise SystemExit(
                    f"v0.6.0 source missing marker in {path.name}: {marker}"
                )

    prepare_version()
    print("PASS: v0.6.0 exact state-predicate source profile applied")
