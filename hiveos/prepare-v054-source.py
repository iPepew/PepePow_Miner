#!/usr/bin/env python3
"""Apply the v0.5.4 lookup/split CUDA performance profile.

Profiler Pack v4 on RTX 3080 showed:
* 74.8% compute throughput but only 4.1% memory throughput;
* 30.7 short-scoreboard stall cycles per issued instruction;
* 34.95% achieved occupancy, with the monolithic kernel using 87 registers;
* only 8.1 active threads per warp due to the rare nonlinear path.

This profile trades spare memory bandwidth for FP64 work by precomputing the
consensus-exact (matrix * 0.0001) * nibble values in a cell-major lookup table.
It also tests a mathematically safe finite-domain fast path and the split
pipeline, whose HooHash kernel needs materially fewer registers than the fused
kernel. Every candidate remains consensus-gated before benchmarking.
"""

from __future__ import annotations

from pathlib import Path
import runpy

ROOT = Path(__file__).resolve().parents[1]
VERSION_FILE = ROOT / "VERSION"
MAIN = ROOT / "native/src/app/main.cpp"
CMAKE = ROOT / "native/CMakeLists.txt"
HEADER = ROOT / "native/include/pepepow/cuda/header80_backend.hpp"
VALIDATION = ROOT / "native/tests/cuda_header80_validation.cpp"
H_RUN = ROOT / "hiveos/h-run.sh"
V053 = ROOT / "native/src/cuda/header80_backend_v053.cu"
V054 = ROOT / "native/src/cuda/header80_backend_v054.cu"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"v0.5.4 source preparation failed: {label}")
    return text.replace(old, new, 1)


def apply_v053_profile() -> None:
    runpy.run_path(str(ROOT / "hiveos/prepare-v053-source.py"), run_name="__main__")


def prepare_version() -> None:
    VERSION_FILE.write_text("0.5.4-PR\n", encoding="utf-8")


def prepare_main() -> None:
    text = MAIN.read_text(encoding="utf-8")
    text = replace_once(
        text,
        'return std::string("PepeW Bit Fraction Edition ") + PEPEPOW_VERSION +',
        'return std::string("PepeW Lookup Split Edition ") + PEPEPOW_VERSION +',
        "build identity",
    )
    text = replace_once(
        text,
        '                  "pipeline=autotune exact_bit_conversions=1 "\n'
        '                  "bit_sw_fraction=autotune derive_two=autotune "\n'
        '                  "nibble_table=autotune hashmod_hoist=1 "\n'
        '                  "scaled_matrix=1 upload_cache=1 prefer_l1=1");',
        '                  "pipeline=autotune exact_bit_conversions=1 "\n'
        '                  "bit_sw_fraction=1 scaled_nibble_table=autotune "\n'
        '                  "assume_finite=autotune hashmod_hoist=1 "\n'
        '                  "scaled_matrix=1 upload_cache=1 prefer_l1=1");',
        "v0.5.4 runtime markers",
    )
    MAIN.write_text(text, encoding="utf-8")


def prepare_header() -> None:
    text = HEADER.read_text(encoding="utf-8")
    text = replace_once(
        text,
        '    void* device_matrix_{nullptr};\n'
        '    void* device_work_{nullptr};',
        '    void* device_matrix_{nullptr};\n'
        '    void* device_scaled_nibble_{nullptr};\n'
        '    void* device_work_{nullptr};',
        "scaled nibble device buffer",
    )
    HEADER.write_text(text, encoding="utf-8")


def prepare_cmake() -> None:
    text = CMAKE.read_text(encoding="utf-8")
    text = replace_once(
        text,
        'option(PEPEPOW_CUDA_NIBBLE_TABLE "Use a constant-memory nibble-to-FP64 table" OFF)\n',
        'option(PEPEPOW_CUDA_NIBBLE_TABLE "Use a constant-memory nibble-to-FP64 table" OFF)\n'
        'option(PEPEPOW_CUDA_SCALED_NIBBLE_TABLE "Use a cell-major exact scaled-matrix/nibble lookup table" OFF)\n'
        'option(PEPEPOW_CUDA_ASSUME_FINITE "Skip unreachable non-finite retry loop for bounded HooHash inputs" OFF)\n',
        "v0.5.4 CUDA options",
    )
    text = replace_once(
        text,
        '        src/cuda/header80_backend_v053.cu\n',
        '        src/cuda/header80_backend_v054.cu\n',
        "v0.5.4 backend selection",
    )
    nibble_block = '''    if(PEPEPOW_CUDA_NIBBLE_TABLE)
        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_NIBBLE_TABLE=1)
    else()
        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_NIBBLE_TABLE=0)
    endif()
'''
    expanded = nibble_block + '''    if(PEPEPOW_CUDA_SCALED_NIBBLE_TABLE)
        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_SCALED_NIBBLE_TABLE=1)
    else()
        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_SCALED_NIBBLE_TABLE=0)
    endif()
    if(PEPEPOW_CUDA_ASSUME_FINITE)
        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_ASSUME_FINITE=1)
    else()
        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_ASSUME_FINITE=0)
    endif()
'''
    text = replace_once(text, nibble_block, expanded, "v0.5.4 compile definitions")
    CMAKE.write_text(text, encoding="utf-8")


def prepare_hive_run() -> None:
    text = H_RUN.read_text(encoding="utf-8")
    text = text.replace(
        "AUTOTUNED_PIPELINE EXACT_BIT_CONVERSIONS BIT_SW_FRACTION DERIVE_TWO NIBBLE_TABLE HASHMOD_HOIST PREFER_L1",
        "AUTOTUNED_PIPELINE EXACT_BIT_CONVERSIONS BIT_SW_FRACTION SCALED_NIBBLE_TABLE ASSUME_FINITE HASHMOD_HOIST PREFER_L1",
    )
    text = text.replace(
        "autotuned monolithic pipeline; exact bit conversions; direct bit fraction(sum/1024); derived nonlinear selector; optional nibble table; hash-mod conversion hoist; PreferL1; persistent buffers; 524288 runtime batch",
        "autotuned monolithic/split pipeline; exact bit conversions; direct bit fraction(sum/1024); optional cell-major scaled-nibble lookup; finite-domain nonlinear fast path; hash-mod conversion hoist; PreferL1; persistent buffers; 524288 runtime batch",
    )
    H_RUN.write_text(text, encoding="utf-8")


def prepare_validation() -> None:
    text = VALIDATION.read_text(encoding="utf-8")
    text = text.replace('sample < 8192U', 'sample < 16384U')
    text = text.replace(
        'PASS: 8192 bit-fraction CPU/CUDA samples match',
        'PASS: 16384 lookup-split CPU/CUDA samples match',
    )
    if 'sample < 16384U' not in text or 'PASS: 16384 lookup-split CPU/CUDA samples match' not in text:
        raise SystemExit("v0.5.4 source preparation failed: validation expansion")
    VALIDATION.write_text(text, encoding="utf-8")


def prepare_cuda() -> None:
    text = V053.read_text(encoding="utf-8")

    text = replace_once(
        text,
        '#ifndef PEPEPOW_CUDA_NIBBLE_TABLE\n#define PEPEPOW_CUDA_NIBBLE_TABLE 0\n#endif\n',
        '#ifndef PEPEPOW_CUDA_NIBBLE_TABLE\n#define PEPEPOW_CUDA_NIBBLE_TABLE 0\n#endif\n'
        '#ifndef PEPEPOW_CUDA_SCALED_NIBBLE_TABLE\n#define PEPEPOW_CUDA_SCALED_NIBBLE_TABLE 0\n#endif\n'
        '#ifndef PEPEPOW_CUDA_ASSUME_FINITE\n#define PEPEPOW_CUDA_ASSUME_FINITE 0\n#endif\n',
        "v0.5.4 CUDA macros",
    )
    text = replace_once(
        text,
        'constexpr std::size_t kMatrixElements = 64 * 64;\n',
        'constexpr std::size_t kMatrixElements = 64 * 64;\n'
        'constexpr std::size_t kScaledNibbleElements = kMatrixElements * 16;\n',
        "scaled nibble element count",
    )

    old_safe = '''__device__ __forceinline__ double safe_nonlinear(double x) {
    double rounds = 1.0;
    double out = nonlinear(x);
    while (isnan(out) || isinf(out)) {
        x *= 0.1;
        if (x <= 1e-13) return 0.0;
        rounds += 1.0;
        out = nonlinear(x);
    }
    return out * rounds;
}'''
    new_safe = '''__device__ __forceinline__ double safe_nonlinear(double x) {
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
    text = replace_once(text, old_safe, new_safe, "finite-domain nonlinear fast path")

    old_accumulate = '''__device__ __forceinline__ void accumulate(
    const double* __restrict__ matrix,
    int cell_index, double value, double hash_mod, double nonce_mod,
    double& sum, double& sw) {
    if (sw <= 0.02) {
        if (value != 0.0) {
            const double cell = matrix[cell_index];
            const double x = cell * hash_mod * value + nonce_mod;
            sum += safe_nonlinear(x) * value * 1234.0;
        }
    } else {
#if PEPEPOW_CUDA_SCALED_MATRIX
        sum += kHeader80ScaledMatrix[cell_index] * value;
#else
        sum += matrix[cell_index] * 0.0001 * value;
#endif
    }
    sw = positive_fraction_div1024_bits(sum);
}'''
    new_accumulate = '''__device__ __forceinline__ void accumulate(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    int cell_index, std::uint32_t nibble, double value,
    double hash_mod, double nonce_mod, double& sum, double& sw) {
    if (sw <= 0.02) {
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
    sw = positive_fraction_div1024_bits(sum);
}'''
    text = replace_once(text, old_accumulate, new_accumulate, "scaled nibble accumulator")

    text = replace_once(
        text,
        '''__device__ __forceinline__ double matrix_row(
    const double* __restrict__ matrix,
    int row, const std::uint32_t first_pass[8], double hash_mod_fp64,
    double nonce_mod, double& sw) {''',
        '''__device__ __forceinline__ double matrix_row(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    int row, const std::uint32_t first_pass[8], double hash_mod_fp64,
    double nonce_mod, double& sw) {''',
        "matrix row lookup pointer",
    )
    old_cells = '''            const int high_cell = row_offset + byte_index * 2;
            accumulate(matrix, high_cell, nibble_to_double(static_cast<std::uint32_t>(packed >> 4U)),
                       hash_mod_fp64, nonce_mod, sum, sw);
            accumulate(matrix, high_cell + 1, nibble_to_double(static_cast<std::uint32_t>(packed & 0x0fU)),
                       hash_mod_fp64, nonce_mod, sum, sw);'''
    new_cells = '''            const int high_cell = row_offset + byte_index * 2;
            const std::uint32_t high_nibble = static_cast<std::uint32_t>(packed >> 4U);
            const std::uint32_t low_nibble = static_cast<std::uint32_t>(packed & 0x0fU);
            accumulate(matrix, scaled_nibble_table, high_cell, high_nibble,
                       nibble_to_double(high_nibble), hash_mod_fp64, nonce_mod, sum, sw);
            accumulate(matrix, scaled_nibble_table, high_cell + 1, low_nibble,
                       nibble_to_double(low_nibble), hash_mod_fp64, nonce_mod, sum, sw);'''
    text = replace_once(text, old_cells, new_cells, "nibble-aware row cells")

    text = replace_once(
        text,
        '''__device__ __forceinline__ void hoohash_mix_words(
    const double* __restrict__ matrix,
    std::uint32_t mix_nonce,''',
        '''__device__ __forceinline__ void hoohash_mix_words(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    std::uint32_t mix_nonce,''',
        "HooHash lookup pointer",
    )
    text = text.replace(
        'matrix_row(matrix, pair * 2, first_pass, hash_mod_fp64, nonce_mod, sw)',
        'matrix_row(matrix, scaled_nibble_table, pair * 2, first_pass, hash_mod_fp64, nonce_mod, sw)',
    )
    text = text.replace(
        'matrix_row(matrix, pair * 2 + 1, first_pass, hash_mod_fp64, nonce_mod, sw)',
        'matrix_row(matrix, scaled_nibble_table, pair * 2 + 1, first_pass, hash_mod_fp64, nonce_mod, sw)',
    )

    text = replace_once(
        text,
        '''void hoohash_mix_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    std::uint32_t* __restrict__ work_words,''',
        '''void hoohash_mix_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    std::uint32_t* __restrict__ work_words,''',
        "split kernel lookup pointer",
    )
    text = replace_once(
        text,
        '    hoohash_mix_words(matrix, mix_nonce, first_pass, mixed);',
        '    hoohash_mix_words(matrix, scaled_nibble_table, mix_nonce, first_pass, mixed);',
        "split HooHash lookup call",
    )
    text = replace_once(
        text,
        '''void header80_pow_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    DeviceShareResult* __restrict__ result,''',
        '''void header80_pow_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    DeviceShareResult* __restrict__ result,''',
        "monolithic kernel lookup pointer",
    )
    text = replace_once(
        text,
        '    hoohash_mix_words(matrix, byte_swap32(nonce), first_pass, mixed);',
        '    hoohash_mix_words(matrix, scaled_nibble_table, byte_swap32(nonce), first_pass, mixed);',
        "monolithic HooHash lookup call",
    )

    text = replace_once(
        text,
        '''Header80CudaBackend::~Header80CudaBackend() {
    if (device_result_ != nullptr || device_matrix_ != nullptr || device_work_ != nullptr) {''',
        '''Header80CudaBackend::~Header80CudaBackend() {
    if (device_result_ != nullptr || device_matrix_ != nullptr ||
        device_scaled_nibble_ != nullptr || device_work_ != nullptr) {''',
        "destructor device check",
    )
    text = replace_once(
        text,
        '''    if (device_matrix_ != nullptr) {
        cudaFree(device_matrix_);
        device_matrix_ = nullptr;
    }
    if (device_work_ != nullptr) {''',
        '''    if (device_matrix_ != nullptr) {
        cudaFree(device_matrix_);
        device_matrix_ = nullptr;
    }
    if (device_scaled_nibble_ != nullptr) {
        cudaFree(device_scaled_nibble_);
        device_scaled_nibble_ = nullptr;
    }
    if (device_work_ != nullptr) {''',
        "destructor scaled nibble free",
    )

    old_upload = '''#if PEPEPOW_CUDA_SCALED_MATRIX
        std::array<double, kMatrixElements> scaled_matrix{};
        const double* matrix_values = matrix.data()->data();
        for (std::size_t cell = 0; cell < kMatrixElements; ++cell) {
            scaled_matrix[cell] = matrix_values[cell] * 0.0001;
        }
        check_cuda_header80(
            cudaMemcpyToSymbol(kHeader80ScaledMatrix, scaled_matrix.data(),
                               kMatrixElements * sizeof(double), 0, cudaMemcpyHostToDevice),
            "cudaMemcpyToSymbol(header80 scaled matrix)");
#endif'''
    new_upload = '''#if PEPEPOW_CUDA_SCALED_MATRIX || PEPEPOW_CUDA_SCALED_NIBBLE_TABLE
        std::array<double, kMatrixElements> scaled_matrix{};
        const double* matrix_values = matrix.data()->data();
        for (std::size_t cell = 0; cell < kMatrixElements; ++cell) {
            scaled_matrix[cell] = matrix_values[cell] * 0.0001;
        }
#endif
#if PEPEPOW_CUDA_SCALED_MATRIX
        check_cuda_header80(
            cudaMemcpyToSymbol(kHeader80ScaledMatrix, scaled_matrix.data(),
                               kMatrixElements * sizeof(double), 0, cudaMemcpyHostToDevice),
            "cudaMemcpyToSymbol(header80 scaled matrix)");
#endif
#if PEPEPOW_CUDA_SCALED_NIBBLE_TABLE
        if (device_scaled_nibble_ == nullptr) {
            check_cuda_header80(
                cudaMalloc(&device_scaled_nibble_, kScaledNibbleElements * sizeof(double)),
                "cudaMalloc(header80 scaled nibble table)");
        }
        std::vector<double> scaled_nibble(kScaledNibbleElements);
        for (std::size_t cell = 0; cell < kMatrixElements; ++cell) {
            const double scaled = scaled_matrix[cell];
            for (std::uint32_t nibble = 0; nibble < 16U; ++nibble) {
                scaled_nibble[cell * 16U + nibble] =
                    scaled * static_cast<double>(nibble);
            }
        }
        check_cuda_header80(
            cudaMemcpy(device_scaled_nibble_, scaled_nibble.data(),
                       kScaledNibbleElements * sizeof(double), cudaMemcpyHostToDevice),
            "cudaMemcpy(header80 scaled nibble table)");
#endif'''
    text = replace_once(text, old_upload, new_upload, "scaled nibble table upload")

    text = replace_once(
        text,
        '''    hoohash_mix_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_), work_words, count);''',
        '''    hoohash_mix_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_), work_words, count);''',
        "split kernel launch",
    )
    text = replace_once(
        text,
        '''    header80_pow_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<DeviceShareResult*>(device_result_), count);''',
        '''    header80_pow_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_),
        static_cast<DeviceShareResult*>(device_result_), count);''',
        "monolithic kernel launch",
    )

    required_markers = (
        "PEPEPOW_CUDA_SCALED_NIBBLE_TABLE",
        "PEPEPOW_CUDA_ASSUME_FINITE",
        "kScaledNibbleElements",
        "device_scaled_nibble_",
        "scaled_nibble_table",
        "HooHash V110 bounds x",
    )
    for marker in required_markers:
        if marker not in text:
            raise SystemExit(f"v0.5.4 CUDA source missing marker: {marker}")
    V054.write_text(text, encoding="utf-8")


def already_prepared() -> bool:
    return (
        V054.exists()
        and VERSION_FILE.read_text(encoding="utf-8").strip() == "0.5.4-PR"
        and "PepeW Lookup Split Edition" in MAIN.read_text(encoding="utf-8")
        and "header80_backend_v054.cu" in CMAKE.read_text(encoding="utf-8")
        and "device_scaled_nibble_" in HEADER.read_text(encoding="utf-8")
    )


if __name__ == "__main__":
    if not already_prepared():
        apply_v053_profile()
        prepare_version()
        prepare_main()
        prepare_header()
        prepare_cmake()
        prepare_hive_run()
        prepare_validation()
        prepare_cuda()

    required = {
        VERSION_FILE: ("0.5.4-PR",),
        MAIN: ("PepeW Lookup Split Edition", "scaled_nibble_table=autotune", "assume_finite=autotune"),
        HEADER: ("device_scaled_nibble_",),
        CMAKE: ("header80_backend_v054.cu", "PEPEPOW_CUDA_SCALED_NIBBLE_TABLE", "PEPEPOW_CUDA_ASSUME_FINITE"),
        H_RUN: ("SCALED_NIBBLE_TABLE", "finite-domain nonlinear fast path"),
        VALIDATION: ("PASS: 16384 lookup-split CPU/CUDA samples match",),
        V054: ("kScaledNibbleElements", "scaled_nibble_table", "PEPEPOW_CUDA_ASSUME_FINITE"),
    }
    for path, markers in required.items():
        value = path.read_text(encoding="utf-8")
        for marker in markers:
            if marker not in value:
                raise SystemExit(f"v0.5.4 source missing marker in {path.name}: {marker}")

    print("PASS: v0.5.4 lookup-split source profile applied")
