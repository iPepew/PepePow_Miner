#!/usr/bin/env python3
"""Apply the v0.5.3 bit-fraction CUDA performance profile.

This profile starts from v0.5.2, repairs the rejected zero-nibble early return,
and adds three independently autotunable, consensus-gated transformations:

* direct IEEE-754 extraction of fraction(sum / 1024) without an FP64 scale;
* derivation of the second nonlinear selector fraction from the first;
* an optional constant-memory table for exact nibble-to-FP64 conversion.

The generated backend remains monolithic by default. Every build candidate must
pass deterministic CPU/CUDA validation before it is benchmarked or packaged.
"""

from __future__ import annotations

from pathlib import Path
import runpy

ROOT = Path(__file__).resolve().parents[1]
MAIN = ROOT / "native/src/app/main.cpp"
CMAKE = ROOT / "native/CMakeLists.txt"
VALIDATION = ROOT / "native/tests/cuda_header80_validation.cpp"
V052 = ROOT / "native/src/cuda/header80_backend_v052.cu"
V053 = ROOT / "native/src/cuda/header80_backend_v053.cu"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"v0.5.3 source preparation failed: {label}")
    return text.replace(old, new, 1)


def apply_v052_profile() -> None:
    runpy.run_path(str(ROOT / "hiveos/prepare-v052-source.py"), run_name="__main__")


def prepare_main() -> None:
    text = MAIN.read_text(encoding="utf-8")
    text = replace_once(
        text,
        'return std::string("PepeW Exact Conversion Edition ") + PEPEPOW_VERSION +',
        'return std::string("PepeW Bit Fraction Edition ") + PEPEPOW_VERSION +',
        "build identity",
    )
    text = replace_once(
        text,
        '                  "pipeline=autotune exact_bit_conversions=autotune "\n'
        '                  "fast_fraction=1 zero_nibble_skip=1 hashmod_hoist=1 "\n'
        '                  "scaled_matrix=1 upload_cache=1 prefer_l1=1");',
        '                  "pipeline=autotune exact_bit_conversions=1 "\n'
        '                  "bit_sw_fraction=autotune derive_two=autotune "\n'
        '                  "nibble_table=autotune hashmod_hoist=1 "\n'
        '                  "scaled_matrix=1 upload_cache=1 prefer_l1=1");',
        "v0.5.3 runtime markers",
    )
    MAIN.write_text(text, encoding="utf-8")


def prepare_cmake() -> None:
    text = CMAKE.read_text(encoding="utf-8")
    text = replace_once(
        text,
        'option(PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS "Use exact IEEE-754 bit conversions in hot HooHash loops" ON)\n',
        'option(PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS "Use exact IEEE-754 bit conversions in hot HooHash loops" ON)\n'
        'option(PEPEPOW_CUDA_BIT_SW_FRACTION "Extract fraction(sum/1024) directly from IEEE-754 bits" ON)\n'
        'option(PEPEPOW_CUDA_DERIVE_TWO "Derive the second nonlinear fraction from the first" ON)\n'
        'option(PEPEPOW_CUDA_NIBBLE_TABLE "Use a constant-memory nibble-to-FP64 table" OFF)\n',
        "v0.5.3 CUDA options",
    )
    text = text.replace(
        'if(NOT PEPEPOW_CUDA_THREADS MATCHES "^(64|128|256|320|384)$")',
        'if(NOT PEPEPOW_CUDA_THREADS MATCHES "^(64|96|128|160|192|256|320|384)$")',
    )
    text = text.replace(
        'PEPEPOW_CUDA_THREADS must be 64, 128, 256, 320 or 384',
        'PEPEPOW_CUDA_THREADS must be 64, 96, 128, 160, 192, 256, 320 or 384',
    )
    text = text.replace(
        'if(NOT PEPEPOW_CUDA_MIN_BLOCKS MATCHES "^[1-4]$")',
        'if(NOT PEPEPOW_CUDA_MIN_BLOCKS MATCHES "^([1-9]|1[0-6])$")',
    )
    text = text.replace(
        'PEPEPOW_CUDA_MIN_BLOCKS must be 1 through 4',
        'PEPEPOW_CUDA_MIN_BLOCKS must be 1 through 16',
    )
    text = replace_once(
        text,
        '        src/cuda/header80_backend_v052.cu\n',
        '        src/cuda/header80_backend_v053.cu\n',
        "v0.5.3 backend selection",
    )
    exact_block = '''    if(PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS)
        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS=1)
    else()
        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS=0)
    endif()
'''
    expanded = exact_block + '''    if(PEPEPOW_CUDA_BIT_SW_FRACTION)
        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_BIT_SW_FRACTION=1)
    else()
        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_BIT_SW_FRACTION=0)
    endif()
    if(PEPEPOW_CUDA_DERIVE_TWO)
        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_DERIVE_TWO=1)
    else()
        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_DERIVE_TWO=0)
    endif()
    if(PEPEPOW_CUDA_NIBBLE_TABLE)
        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_NIBBLE_TABLE=1)
    else()
        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_NIBBLE_TABLE=0)
    endif()
'''
    text = replace_once(text, exact_block, expanded, "v0.5.3 compile definitions")
    CMAKE.write_text(text, encoding="utf-8")


def prepare_validation() -> None:
    text = VALIDATION.read_text(encoding="utf-8")
    text = text.replace('sample < 4096U', 'sample < 8192U')
    text = text.replace(
        'PASS: 4096 exact-conversion CPU/CUDA samples match',
        'PASS: 8192 bit-fraction CPU/CUDA samples match',
    )
    if 'sample < 8192U' not in text or 'PASS: 8192 bit-fraction CPU/CUDA samples match' not in text:
        raise SystemExit("v0.5.3 source preparation failed: validation expansion")
    VALIDATION.write_text(text, encoding="utf-8")


def prepare_cuda() -> None:
    text = V052.read_text(encoding="utf-8")

    # v0.5.2's initial zero-nibble early return was rejected by consensus at a
    # row boundary because sum resets to zero while sw is carried between rows.
    unsafe = '''    if (value == 0.0) return;
    if (sw <= 0.02) {
        const double cell = matrix[cell_index];
        const double x = cell * hash_mod * value + nonce_mod;
        sum += safe_nonlinear(x) * value * 1234.0;
    } else {'''
    safe = '''    if (sw <= 0.02) {
        if (value != 0.0) {
            const double cell = matrix[cell_index];
            const double x = cell * hash_mod * value + nonce_mod;
            sum += safe_nonlinear(x) * value * 1234.0;
        }
    } else {'''
    if unsafe in text:
        text = text.replace(unsafe, safe, 1)
    elif safe not in text:
        raise SystemExit("v0.5.3 source preparation failed: consensus accumulator repair")

    text = replace_once(
        text,
        '#ifndef PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS\n#define PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS 1\n#endif\n',
        '#ifndef PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS\n#define PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS 1\n#endif\n'
        '#ifndef PEPEPOW_CUDA_BIT_SW_FRACTION\n#define PEPEPOW_CUDA_BIT_SW_FRACTION 1\n#endif\n'
        '#ifndef PEPEPOW_CUDA_DERIVE_TWO\n#define PEPEPOW_CUDA_DERIVE_TWO 1\n#endif\n'
        '#ifndef PEPEPOW_CUDA_NIBBLE_TABLE\n#define PEPEPOW_CUDA_NIBBLE_TABLE 0\n#endif\n',
        "v0.5.3 CUDA macros",
    )

    text = replace_once(
        text,
        '__device__ __constant__ std::uint32_t kHeader80TargetWords[8];\n',
        '__device__ __constant__ std::uint32_t kHeader80TargetWords[8];\n'
        '__device__ __constant__ double kHeader80NibbleFp64[16] = {\n'
        '    0.0, 1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0,\n'
        '    8.0, 9.0, 10.0, 11.0, 12.0, 13.0, 14.0, 15.0};\n',
        "nibble FP64 table",
    )

    fraction_marker = '__device__ __forceinline__ double positive_fraction_bits(double value) {'
    nibble_helper = '''__device__ __forceinline__ double nibble_to_double(std::uint32_t value) {
#if PEPEPOW_CUDA_NIBBLE_TABLE
    return kHeader80NibbleFp64[value & 0x0fU];
#else
    return u32_to_double_exact(value & 0x0fU);
#endif
}

''' + fraction_marker
    text = replace_once(text, fraction_marker, nibble_helper, "nibble conversion helper")

    u64_marker = '__device__ __forceinline__ std::uint64_t positive_double_to_u64_rz(double value) {'
    scaled_fraction_helper = r'''__device__ __forceinline__ double positive_fraction_div1024_bits(double value) {
#if PEPEPOW_CUDA_BIT_SW_FRACTION
    if (value == 0.0) return 0.0;
    const std::uint64_t bits = static_cast<std::uint64_t>(__double_as_longlong(value));
    const unsigned int exponent = static_cast<unsigned int>((bits >> 52U) & 0x7ffU);
    if (exponent == 0U || exponent == 0x7ffU || exponent <= 10U) {
        return positive_fraction_bits(value * 0x1.0p-10);
    }
    const unsigned int scaled_exponent = exponent - 10U;
    if (scaled_exponent < 1023U) {
        const std::uint64_t scaled_bits =
            (bits & kDoubleMantissaMask) |
            (static_cast<std::uint64_t>(scaled_exponent) << 52U);
        return __longlong_as_double(static_cast<long long>(scaled_bits));
    }
    const unsigned int integer_bits = scaled_exponent - 1023U;
    if (integer_bits >= 52U) return 0.0;
    const unsigned int fractional_width = 52U - integer_bits;
    const std::uint64_t fraction_mask =
        (std::uint64_t{1} << fractional_width) - std::uint64_t{1};
    const std::uint64_t fraction = bits & fraction_mask;
    if (fraction == 0U) return 0.0;
    const unsigned int msb = 63U - static_cast<unsigned int>(__clzll(fraction));
    const int result_exponent = 1023 + static_cast<int>(msb) -
                                static_cast<int>(fractional_width);
    const std::uint64_t normalized = fraction << (52U - msb);
    const std::uint64_t result_bits =
        (static_cast<std::uint64_t>(result_exponent) << 52U) |
        (normalized & kDoubleMantissaMask);
    return __longlong_as_double(static_cast<long long>(result_bits));
#else
    return positive_fraction(value / 1024.0);
#endif
}

''' + u64_marker
    text = replace_once(text, u64_marker, scaled_fraction_helper, "scaled fraction helper")

    old_selectors = '''    const double one_base = x * kTransformMultiplier / 8.0;
    const double two_base = x * kTransformMultiplier / 4.0;
    const double one = positive_fraction(one_base);
    const double two = positive_fraction(two_base);'''
    new_selectors = '''    const double scaled = x * kTransformMultiplier;
    const double one_base = scaled / 8.0;
    const double one = positive_fraction(one_base);
#if PEPEPOW_CUDA_DERIVE_TWO
    const double doubled_one = one + one;
    const double two = doubled_one >= 1.0 ? doubled_one - 1.0 : doubled_one;
#else
    const double two = positive_fraction(scaled / 4.0);
#endif'''
    text = replace_once(text, old_selectors, new_selectors, "derived nonlinear selector")

    text = replace_once(
        text,
        '    sw = positive_fraction(sum / 1024.0);',
        '    sw = positive_fraction_div1024_bits(sum);',
        "direct sw fraction",
    )
    text = text.replace(
        'u32_to_double_exact(static_cast<std::uint32_t>(packed >> 4U))',
        'nibble_to_double(static_cast<std::uint32_t>(packed >> 4U))',
    )
    text = text.replace(
        'u32_to_double_exact(static_cast<std::uint32_t>(packed & 0x0fU))',
        'nibble_to_double(static_cast<std::uint32_t>(packed & 0x0fU))',
    )

    for marker in (
        "PEPEPOW_CUDA_BIT_SW_FRACTION",
        "PEPEPOW_CUDA_DERIVE_TWO",
        "PEPEPOW_CUDA_NIBBLE_TABLE",
        "positive_fraction_div1024_bits",
        "doubled_one",
        "nibble_to_double",
    ):
        if marker not in text:
            raise SystemExit(f"v0.5.3 CUDA source missing marker: {marker}")
    if "if (value == 0.0) return;" in text:
        raise SystemExit("v0.5.3 CUDA source still contains unsafe zero-nibble early return")
    V053.write_text(text, encoding="utf-8")


def already_prepared() -> bool:
    return (
        V053.exists()
        and "PepeW Bit Fraction Edition" in MAIN.read_text(encoding="utf-8")
        and "header80_backend_v053.cu" in CMAKE.read_text(encoding="utf-8")
    )


if __name__ == "__main__":
    if not already_prepared():
        apply_v052_profile()
        prepare_main()
        prepare_cmake()
        prepare_validation()
        prepare_cuda()

    required = {
        MAIN: ("PepeW Bit Fraction Edition", "bit_sw_fraction=autotune", "derive_two=autotune"),
        CMAKE: ("header80_backend_v053.cu", "PEPEPOW_CUDA_BIT_SW_FRACTION", "PEPEPOW_CUDA_DERIVE_TWO", "PEPEPOW_CUDA_NIBBLE_TABLE"),
        VALIDATION: ("PASS: 8192 bit-fraction CPU/CUDA samples match",),
        V053: ("positive_fraction_div1024_bits", "doubled_one", "nibble_to_double"),
    }
    for path, markers in required.items():
        value = path.read_text(encoding="utf-8")
        for marker in markers:
            if marker not in value:
                raise SystemExit(f"v0.5.3 source missing marker in {path.name}: {marker}")

    print("PASS: v0.5.3 bit-fraction source profile applied")
