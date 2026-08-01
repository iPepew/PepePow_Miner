#!/usr/bin/env python3
"""Apply the v0.5.2 exact-conversion CUDA profile.

The RTX 3080 profiler shows that v0.5.1 is compute-bound in the selected
monolithic 64-thread kernel: GPU utilization is 100%, memory utilization is
about 1%, clocks are stable and no throttle reason is active. This profile
removes repeated FP64<->integer conversions from the hot HooHash loop by using
exact IEEE-754 bit decomposition. It also skips zero nibbles without
recomputing an unchanged state and hoists hash_mod conversion out of every
matrix row. All changes are protected by CPU/CUDA consensus validation and are
autotuned against the unchanged v0.5.1 conversion path.
"""

from __future__ import annotations

from pathlib import Path
import runpy

ROOT = Path(__file__).resolve().parents[1]
MAIN = ROOT / "native/src/app/main.cpp"
CMAKE = ROOT / "native/CMakeLists.txt"
VALIDATION = ROOT / "native/tests/cuda_header80_validation.cpp"
V051 = ROOT / "native/src/cuda/header80_backend_v051.cu"
V052 = ROOT / "native/src/cuda/header80_backend_v052.cu"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"v0.5.2 source preparation failed: {label}")
    return text.replace(old, new, 1)


def apply_v051_profile() -> None:
    runpy.run_path(str(ROOT / "hiveos/prepare-v051-source.py"), run_name="__main__")


def prepare_main() -> None:
    text = MAIN.read_text(encoding="utf-8")
    text = replace_once(
        text,
        'return std::string("PepeW Split Pipeline Edition ") + PEPEPOW_VERSION +',
        'return std::string("PepeW Exact Conversion Edition ") + PEPEPOW_VERSION +',
        "build identity",
    )
    text = replace_once(
        text,
        '        // 348,160 nonces matches the 320-thread/1,088-block RTX 3080\n'
        '        // performance profile while keeping clean-job latency low.\n'
        '        constexpr std::uint64_t chunk_size = 348160;',
        '        // The profiler-selected v0.5.1 binary is monolithic. A 524,288\n'
        '        // nonce batch reduces host synchronization while keeping clean-job\n'
        '        // switch latency below one second at the measured RTX 3080 rate.\n'
        '        constexpr std::uint64_t chunk_size = 524288;',
        "runtime batch",
    )
    text = replace_once(
        text,
        '                  "batch=348160 gpu_stats=per_device word_pipeline=1 "\n'
        '                  "split_pipeline=autotune fast_fraction=autotune "\n'
        '                  "scaled_matrix=1 upload_cache=1 prefer_l1=1");',
        '                  "batch=524288 gpu_stats=per_device word_pipeline=1 "\n'
        '                  "pipeline=autotune exact_bit_conversions=autotune "\n'
        '                  "fast_fraction=1 zero_nibble_skip=1 hashmod_hoist=1 "\n'
        '                  "scaled_matrix=1 upload_cache=1 prefer_l1=1");',
        "v0.5.2 runtime markers",
    )
    MAIN.write_text(text, encoding="utf-8")


def prepare_cmake() -> None:
    text = CMAKE.read_text(encoding="utf-8")
    text = replace_once(
        text,
        'option(PEPEPOW_CUDA_FAST_FRACTION "Use exact positive fraction conversion path" ON)\n',
        'option(PEPEPOW_CUDA_FAST_FRACTION "Use exact positive fraction conversion path" ON)\n'
        'option(PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS "Use exact IEEE-754 bit conversions in hot HooHash loops" ON)\n',
        "exact conversion option",
    )
    text = replace_once(
        text,
        '        src/cuda/header80_backend_v051.cu\n',
        '        src/cuda/header80_backend_v052.cu\n',
        "v0.5.2 backend selection",
    )
    text = replace_once(
        text,
        '    if(PEPEPOW_CUDA_FAST_FRACTION)\n'
        '        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_FAST_FRACTION=1)\n'
        '    else()\n'
        '        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_FAST_FRACTION=0)\n'
        '    endif()\n',
        '    if(PEPEPOW_CUDA_FAST_FRACTION)\n'
        '        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_FAST_FRACTION=1)\n'
        '    else()\n'
        '        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_FAST_FRACTION=0)\n'
        '    endif()\n'
        '    if(PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS)\n'
        '        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS=1)\n'
        '    else()\n'
        '        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS=0)\n'
        '    endif()\n',
        "exact conversion compile definition",
    )
    CMAKE.write_text(text, encoding="utf-8")


def prepare_validation() -> None:
    text = VALIDATION.read_text(encoding="utf-8")
    text = text.replace('sample < 1024U', 'sample < 4096U')
    text = text.replace(
        'PASS: 1024 split-pipeline CPU/CUDA samples match',
        'PASS: 4096 exact-conversion CPU/CUDA samples match',
    )
    if 'sample < 4096U' not in text or 'PASS: 4096 exact-conversion CPU/CUDA samples match' not in text:
        raise SystemExit("v0.5.2 source preparation failed: validation expansion")
    VALIDATION.write_text(text, encoding="utf-8")


def prepare_cuda() -> None:
    text = V051.read_text(encoding="utf-8")
    text = replace_once(
        text,
        '#ifndef PEPEPOW_CUDA_FAST_FRACTION\n#define PEPEPOW_CUDA_FAST_FRACTION 1\n#endif\n',
        '#ifndef PEPEPOW_CUDA_FAST_FRACTION\n#define PEPEPOW_CUDA_FAST_FRACTION 1\n#endif\n'
        '#ifndef PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS\n#define PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS 1\n#endif\n',
        "exact conversion macro",
    )

    insertion_point = '''__device__ __forceinline__ std::uint32_t byte_swap32(std::uint32_t value) {
    return __byte_perm(value, 0U, 0x0123U);
}
'''
    helpers = insertion_point + r'''

constexpr std::uint64_t kDoubleMantissaMask = (std::uint64_t{1} << 52U) - 1U;

__device__ __forceinline__ double u32_to_double_exact(std::uint32_t value) {
#if PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS
    if (value == 0U) return 0.0;
    const unsigned int msb = 31U - static_cast<unsigned int>(__clz(value));
    const std::uint64_t normalized = static_cast<std::uint64_t>(value) << (52U - msb);
    const std::uint64_t bits =
        (static_cast<std::uint64_t>(1023U + msb) << 52U) |
        (normalized & kDoubleMantissaMask);
    return __longlong_as_double(static_cast<long long>(bits));
#else
    return static_cast<double>(value);
#endif
}

__device__ __forceinline__ double positive_fraction_bits(double value) {
    const std::uint64_t bits = static_cast<std::uint64_t>(__double_as_longlong(value));
    const unsigned int exponent = static_cast<unsigned int>((bits >> 52U) & 0x7ffU);
    if (exponent < 1023U) return value;
    const unsigned int integer_bits = exponent - 1023U;
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
}

__device__ __forceinline__ std::uint64_t positive_double_to_u64_rz(double value) {
#if PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS
    const std::uint64_t bits = static_cast<std::uint64_t>(__double_as_longlong(value));
    const unsigned int exponent = static_cast<unsigned int>((bits >> 52U) & 0x7ffU);
    if (exponent < 1023U) return 0U;
    const unsigned int integer_bits = exponent - 1023U;
    if (integer_bits >= 64U || exponent == 0x7ffU) {
        return static_cast<std::uint64_t>(__double2ull_rz(value));
    }
    const std::uint64_t significand =
        (std::uint64_t{1} << 52U) | (bits & kDoubleMantissaMask);
    if (integer_bits >= 52U) return significand << (integer_bits - 52U);
    return significand >> (52U - integer_bits);
#else
    return static_cast<std::uint64_t>(value);
#endif
}
'''
    text = replace_once(text, insertion_point, helpers, "IEEE-754 exact helpers")

    old_fraction = '''__device__ __forceinline__ double positive_fraction(double value) {
#if PEPEPOW_CUDA_FAST_FRACTION
    // All HooHash inputs are non-negative. Below 2^52, conversion with
    // round-toward-zero is exactly floor(); at and above 2^52 every FP64
    // value is integral. This preserves consensus while avoiding floor().
    if (value >= 0x1.0p52) return 0.0;
    return value - static_cast<double>(__double2ull_rz(value));
#else
    return value - floor(value);
#endif
}
'''
    new_fraction = '''__device__ __forceinline__ double positive_fraction(double value) {
#if PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS
    return positive_fraction_bits(value);
#elif PEPEPOW_CUDA_FAST_FRACTION
    if (value >= 0x1.0p52) return 0.0;
    return value - static_cast<double>(__double2ull_rz(value));
#else
    return value - floor(value);
#endif
}
'''
    text = replace_once(text, old_fraction, new_fraction, "bit-exact fraction path")

    text = replace_once(
        text,
        '''    if (sw <= 0.02) {
        if (value != 0.0) {
            const double cell = matrix[cell_index];
            const double x = cell * hash_mod * value + nonce_mod;
            sum += safe_nonlinear(x) * value * 1234.0;
        }
    } else {''',
        '''    if (value == 0.0) return;
    if (sw <= 0.02) {
        const double cell = matrix[cell_index];
        const double x = cell * hash_mod * value + nonce_mod;
        sum += safe_nonlinear(x) * value * 1234.0;
    } else {''',
        "zero nibble fast return",
    )
    text = replace_once(
        text,
        '''    int row, const std::uint32_t first_pass[8], std::uint32_t hash_mod,
    double nonce_mod, double& sw) {
    double sum = 0.0;
    const double hash_mod_fp64 = static_cast<double>(hash_mod);''',
        '''    int row, const std::uint32_t first_pass[8], double hash_mod_fp64,
    double nonce_mod, double& sw) {
    double sum = 0.0;''',
        "hoist hash_mod conversion",
    )
    text = text.replace(
        'static_cast<double>(packed >> 4U)',
        'u32_to_double_exact(static_cast<std::uint32_t>(packed >> 4U))',
    )
    text = text.replace(
        'static_cast<double>(packed & 0x0fU)',
        'u32_to_double_exact(static_cast<std::uint32_t>(packed & 0x0fU))',
    )
    text = replace_once(
        text,
        '''    const std::uint32_t hash_mod = byte_swap32(hash_xor);
    const double nonce_mod = static_cast<double>(mix_nonce & 0xffU);''',
        '''    const std::uint32_t hash_mod = byte_swap32(hash_xor);
    const double hash_mod_fp64 = u32_to_double_exact(hash_mod);
    const double nonce_mod = u32_to_double_exact(mix_nonce & 0xffU);''',
        "exact invariant conversions",
    )
    text = text.replace(
        'matrix_row(matrix, pair * 2, first_pass, hash_mod, nonce_mod, sw)',
        'matrix_row(matrix, pair * 2, first_pass, hash_mod_fp64, nonce_mod, sw)',
    )
    text = text.replace(
        'matrix_row(matrix, pair * 2 + 1, first_pass, hash_mod, nonce_mod, sw)',
        'matrix_row(matrix, pair * 2 + 1, first_pass, hash_mod_fp64, nonce_mod, sw)',
    )
    text = replace_once(
        text,
        '''        const std::uint64_t combined = static_cast<std::uint64_t>(even_sum) +
                                       static_cast<std::uint64_t>(odd_sum);''',
        '''        const std::uint64_t combined = positive_double_to_u64_rz(even_sum) +
                                       positive_double_to_u64_rz(odd_sum);''',
        "exact FP64-to-U64 conversion",
    )

    for marker in (
        "PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS",
        "u32_to_double_exact",
        "positive_fraction_bits",
        "positive_double_to_u64_rz",
        "if (value == 0.0) return;",
        "hash_mod_fp64 = u32_to_double_exact(hash_mod)",
    ):
        if marker not in text:
            raise SystemExit(f"v0.5.2 CUDA source missing marker: {marker}")
    V052.write_text(text, encoding="utf-8")


def already_prepared() -> bool:
    return (
        V052.exists()
        and "PepeW Exact Conversion Edition" in MAIN.read_text(encoding="utf-8")
        and "header80_backend_v052.cu" in CMAKE.read_text(encoding="utf-8")
    )


if __name__ == "__main__":
    if not already_prepared():
        apply_v051_profile()
        prepare_main()
        prepare_cmake()
        prepare_validation()
        prepare_cuda()

    required = {
        MAIN: ("PepeW Exact Conversion Edition", "chunk_size = 524288", "exact_bit_conversions=autotune"),
        CMAKE: ("header80_backend_v052.cu", "PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS"),
        VALIDATION: ("PASS: 4096 exact-conversion CPU/CUDA samples match",),
        V052: ("u32_to_double_exact", "positive_fraction_bits", "positive_double_to_u64_rz", "if (value == 0.0) return;"),
    }
    for path, markers in required.items():
        value = path.read_text(encoding="utf-8")
        for marker in markers:
            if marker not in value:
                raise SystemExit(f"v0.5.2 source missing marker in {path.name}: {marker}")

    print("PASS: v0.5.2 exact-conversion source profile applied")
