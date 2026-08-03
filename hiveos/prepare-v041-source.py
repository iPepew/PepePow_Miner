#!/usr/bin/env python3
"""Apply the deterministic v0.4.1 CUDA matrix-cache release profile.

The script first applies the proven v0.4.0 HiveOS/runtime profile, then adds a
consensus-preserving lookup table for the dominant linear HooHash matrix path.
It is idempotent so CI and the HiveOS builder can run it independently.
"""

from __future__ import annotations

from pathlib import Path
import runpy

ROOT = Path(__file__).resolve().parents[1]
MAIN = ROOT / "native/src/app/main.cpp"
CUDA = ROOT / "native/src/cuda/header80_backend.cu"
HEADER = ROOT / "native/include/pepepow/cuda/header80_backend.hpp"
CMAKE = ROOT / "native/CMakeLists.txt"
VALIDATION = ROOT / "native/tests/cuda_header80_validation.cpp"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"v0.4.1 source preparation failed: {label}")
    return text.replace(old, new, 1)


def apply_v040_profile() -> None:
    runpy.run_path(str(ROOT / "hiveos/prepare-v040-source.py"), run_name="__main__")


def prepare_main() -> None:
    text = MAIN.read_text(encoding="utf-8")
    text = replace_once(
        text,
        'return std::string("PepeW Performance & Stability Edition ") + PEPEPOW_VERSION +',
        'return std::string("PepeW Matrix Cache Edition ") + PEPEPOW_VERSION +',
        "build identity",
    )
    text = replace_once(
        text,
        '                  "batch=524288 gpu_stats=per_device");',
        '                  "batch=524288 gpu_stats=per_device cheap_matrix_lut=autotune");',
        "runtime optimization marker",
    )
    MAIN.write_text(text, encoding="utf-8")


def prepare_header() -> None:
    text = HEADER.read_text(encoding="utf-8")
    text = replace_once(
        text,
        '    void* device_result_{nullptr};\n',
        '    void* device_result_{nullptr};\n'
        '    void* device_cheap_table_{nullptr};\n',
        "persistent cheap-table device buffer",
    )
    HEADER.write_text(text, encoding="utf-8")


def prepare_cmake() -> None:
    text = CMAKE.read_text(encoding="utf-8")
    text = replace_once(
        text,
        'set(PEPEPOW_CUDA_THREADS "128" CACHE STRING "CUDA threads per Header80 search block")\n',
        'set(PEPEPOW_CUDA_THREADS "128" CACHE STRING "CUDA threads per Header80 search block")\n'
        'option(PEPEPOW_CUDA_CHEAP_LUT "Precompute exact linear matrix contributions" ON)\n'
        'set(PEPEPOW_CUDA_BYTE_UNROLL "1" CACHE STRING "HooHash byte-loop unroll factor")\n',
        "CUDA matrix-cache options",
    )
    text = replace_once(
        text,
        '    if(NOT PEPEPOW_CUDA_THREADS MATCHES "^(64|128|256)$")\n'
        '        message(FATAL_ERROR "PEPEPOW_CUDA_THREADS must be 64, 128 or 256")\n'
        '    endif()\n',
        '    if(NOT PEPEPOW_CUDA_THREADS MATCHES "^(64|128|256)$")\n'
        '        message(FATAL_ERROR "PEPEPOW_CUDA_THREADS must be 64, 128 or 256")\n'
        '    endif()\n'
        '    if(NOT PEPEPOW_CUDA_BYTE_UNROLL MATCHES "^(1|2|4|8)$")\n'
        '        message(FATAL_ERROR "PEPEPOW_CUDA_BYTE_UNROLL must be 1, 2, 4 or 8")\n'
        '    endif()\n',
        "CUDA byte-unroll validation",
    )
    text = replace_once(
        text,
        '    target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_THREADS=${PEPEPOW_CUDA_THREADS})\n',
        '    target_compile_definitions(pepepow_cuda PRIVATE\n'
        '        PEPEPOW_CUDA_THREADS=${PEPEPOW_CUDA_THREADS}\n'
        '        PEPEPOW_CUDA_BYTE_UNROLL=${PEPEPOW_CUDA_BYTE_UNROLL})\n'
        '    if(PEPEPOW_CUDA_CHEAP_LUT)\n'
        '        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_CHEAP_LUT=1)\n'
        '    else()\n'
        '        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_CHEAP_LUT=0)\n'
        '    endif()\n',
        "CUDA profile definitions",
    )
    CMAKE.write_text(text, encoding="utf-8")


def prepare_validation() -> None:
    text = VALIDATION.read_text(encoding="utf-8")
    text = replace_once(
        text,
        '        std::cout << "PASS: canonical header80 CPU/CUDA hashes match\\n";\n',
        '        std::cout << "PASS: canonical header80 CPU/CUDA hashes match\\n";\n'
        '        std::uint32_t deterministic_nonce = 0x9e3779b9U;\n'
        '        for (std::size_t sample = 0; sample < 256U; ++sample) {\n'
        '            deterministic_nonce = deterministic_nonce * 1664525U + 1013904223U;\n'
        '            auto job = make_validation_job();\n'
        '            job.nonce = deterministic_nonce;\n'
        '            const auto header = pepepow::build_header80(job);\n'
        '            const auto cpu_hash = pepepow::crypto::calculate_header80_pow(header);\n'
        '            const auto gpu_candidate = backend.search(\n'
        '                job, pepepow::SearchRange{deterministic_nonce, 1U}, maximum_target);\n'
        '            if (!gpu_candidate.has_value() || gpu_candidate->nonce != deterministic_nonce ||\n'
        '                gpu_candidate->hash != cpu_hash) {\n'
        '                throw std::runtime_error("deterministic CPU/CUDA sample mismatch");\n'
        '            }\n'
        '        }\n'
        '        std::cout << "PASS: 256 deterministic CPU/CUDA samples match\\n";\n',
        "deterministic CUDA sample validation",
    )
    VALIDATION.write_text(text, encoding="utf-8")


def prepare_cuda() -> None:
    text = CUDA.read_text(encoding="utf-8")
    text = replace_once(
        text,
        '#ifndef PEPEPOW_CUDA_THREADS\n#define PEPEPOW_CUDA_THREADS 128\n#endif\n\n'
        'constexpr std::size_t kHashSize = 32;',
        '#ifndef PEPEPOW_CUDA_THREADS\n#define PEPEPOW_CUDA_THREADS 128\n#endif\n'
        '#ifndef PEPEPOW_CUDA_CHEAP_LUT\n#define PEPEPOW_CUDA_CHEAP_LUT 1\n#endif\n'
        '#ifndef PEPEPOW_CUDA_BYTE_UNROLL\n#define PEPEPOW_CUDA_BYTE_UNROLL 1\n#endif\n\n'
        'constexpr std::size_t kHashSize = 32;',
        "CUDA matrix-cache macros",
    )
    text = replace_once(
        text,
        'constexpr std::size_t kMatrixElements = 64 * 64;\n',
        'constexpr std::size_t kMatrixElements = 64 * 64;\n'
        'constexpr std::size_t kNibbleValues = 16;\n'
        'constexpr std::size_t kCheapTableElements = kMatrixElements * kNibbleValues;\n',
        "matrix-cache dimensions",
    )

    old_accumulate = '''__device__ __forceinline__ void accumulate(
    double cell, double value, double hash_mod, double nonce_mod,
    double& sum, double& sw) {
    if (sw <= 0.02) {
        // A zero nibble contributes exactly zero. Avoid expensive trig/exp work
        // without changing the consensus result or the sw update.
        if (value != 0.0) {
            const double x = cell * hash_mod * value + nonce_mod;
            sum += safe_nonlinear(x) * value * 1234.0;
        }
    } else {
        sum += cell * 0.0001 * value;
    }
    sw = sum / 1024.0 - floor(sum / 1024.0);
}
'''
    new_accumulate = '''__device__ __forceinline__ void accumulate(
    int cell_index, double cheap_contribution, double value,
    double hash_mod, double nonce_mod, double& sum, double& sw) {
    if (sw <= 0.02) {
        // A zero nibble contributes exactly zero. Avoid expensive trig/exp work
        // without changing the consensus result or the sw update.
        if (value != 0.0) {
            const double cell = kHeader80Matrix[cell_index];
            const double x = cell * hash_mod * value + nonce_mod;
            sum += safe_nonlinear(x) * value * 1234.0;
        }
    } else {
#if PEPEPOW_CUDA_CHEAP_LUT
        sum += cheap_contribution;
#else
        const double cell = kHeader80Matrix[cell_index];
        sum += cell * 0.0001 * value;
#endif
    }
    sw = sum / 1024.0 - floor(sum / 1024.0);
}
'''
    text = replace_once(text, old_accumulate, new_accumulate, "linear-path lookup use")

    old_matrix_row = '''__device__ double matrix_row(
    int row, const std::uint8_t first_pass[32], std::uint32_t hash_mod,
    double nonce_mod, double& sw) {
    double sum = 0.0;
    const double hash_mod_fp64 = static_cast<double>(hash_mod);
    const int row_offset = row * 64;
    #pragma unroll 1
    for (int byte_index = 0; byte_index < 32; ++byte_index) {
        const std::uint8_t packed = first_pass[byte_index];
        const int column = byte_index * 2;
        accumulate(kHeader80Matrix[row_offset + column],
                   static_cast<double>(packed >> 4U), hash_mod_fp64, nonce_mod, sum, sw);
        accumulate(kHeader80Matrix[row_offset + column + 1],
                   static_cast<double>(packed & 0x0fU), hash_mod_fp64, nonce_mod, sum, sw);
    }
    return sum;
}
'''
    new_matrix_row = '''__device__ __forceinline__ double matrix_row(
    int row, const std::uint8_t first_pass[32], std::uint32_t hash_mod,
    double nonce_mod, const double* __restrict__ cheap_table, double& sw) {
    double sum = 0.0;
    const double hash_mod_fp64 = static_cast<double>(hash_mod);
    const int row_offset = row * 64;
#if PEPEPOW_CUDA_BYTE_UNROLL == 8
    #pragma unroll 8
#elif PEPEPOW_CUDA_BYTE_UNROLL == 4
    #pragma unroll 4
#elif PEPEPOW_CUDA_BYTE_UNROLL == 2
    #pragma unroll 2
#else
    #pragma unroll 1
#endif
    for (int byte_index = 0; byte_index < 32; ++byte_index) {
        const std::uint8_t packed = first_pass[byte_index];
        const std::uint8_t high = static_cast<std::uint8_t>(packed >> 4U);
        const std::uint8_t low = static_cast<std::uint8_t>(packed & 0x0fU);
        const int column = byte_index * 2;
        const int high_cell = row_offset + column;
        const int low_cell = high_cell + 1;
#if PEPEPOW_CUDA_CHEAP_LUT
        const double high_cheap = cheap_table[
            static_cast<std::size_t>(high_cell) * kNibbleValues + high];
        const double low_cheap = cheap_table[
            static_cast<std::size_t>(low_cell) * kNibbleValues + low];
#else
        const double high_cheap = 0.0;
        const double low_cheap = 0.0;
#endif
        accumulate(high_cell, high_cheap,
                   static_cast<double>(high), hash_mod_fp64, nonce_mod, sum, sw);
        accumulate(low_cell, low_cheap,
                   static_cast<double>(low), hash_mod_fp64, nonce_mod, sum, sw);
    }
    return sum;
}
'''
    text = replace_once(text, old_matrix_row, new_matrix_row, "matrix-row cache path")

    text = replace_once(
        text,
        '''__global__ void header80_pow_kernel(
    std::uint32_t first_nonce,
    DeviceShareResult* __restrict__ result,
    std::size_t count) {''',
        '''__global__ void header80_pow_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ cheap_table,
    DeviceShareResult* __restrict__ result,
    std::size_t count) {''',
        "kernel cache parameter",
    )
    text = replace_once(
        text,
        '''        const double even_sum = matrix_row(pair * 2, first_pass, hash_mod, nonce_mod, sw);
        const double odd_sum = matrix_row(pair * 2 + 1, first_pass, hash_mod, nonce_mod, sw);''',
        '''        const double even_sum = matrix_row(
            pair * 2, first_pass, hash_mod, nonce_mod, cheap_table, sw);
        const double odd_sum = matrix_row(
            pair * 2 + 1, first_pass, hash_mod, nonce_mod, cheap_table, sw);''',
        "kernel matrix-row calls",
    )

    text = replace_once(
        text,
        '''Header80CudaBackend::~Header80CudaBackend() {
    if (device_result_ != nullptr) {
        cudaSetDevice(device_index_);
        cudaFree(device_result_);
        device_result_ = nullptr;
    }
}''',
        '''Header80CudaBackend::~Header80CudaBackend() {
    if (device_result_ != nullptr || device_cheap_table_ != nullptr) {
        cudaSetDevice(device_index_);
    }
    if (device_result_ != nullptr) {
        cudaFree(device_result_);
        device_result_ = nullptr;
    }
    if (device_cheap_table_ != nullptr) {
        cudaFree(device_cheap_table_);
        device_cheap_table_ = nullptr;
    }
}''',
        "matrix-cache cleanup",
    )

    old_upload = '''        const crypto::HoohashMatrix matrix = crypto::generate_hoohash_matrix(matrix_seed);
        check_cuda_header80(
            cudaMemcpyToSymbol(kHeader80Matrix, matrix.data()->data(),
                               kMatrixElements * sizeof(double), 0, cudaMemcpyHostToDevice),
            "cudaMemcpyToSymbol(header80 matrix)");'''
    new_upload = '''        const crypto::HoohashMatrix matrix = crypto::generate_hoohash_matrix(matrix_seed);
        check_cuda_header80(
            cudaMemcpyToSymbol(kHeader80Matrix, matrix.data()->data(),
                               kMatrixElements * sizeof(double), 0, cudaMemcpyHostToDevice),
            "cudaMemcpyToSymbol(header80 matrix)");
#if PEPEPOW_CUDA_CHEAP_LUT
        if (device_cheap_table_ == nullptr) {
            check_cuda_header80(
                cudaMalloc(&device_cheap_table_, kCheapTableElements * sizeof(double)),
                "cudaMalloc(header80 cheap matrix table)");
        }
        std::vector<double> cheap_table(kCheapTableElements);
        const double* matrix_values = matrix.data()->data();
        for (std::size_t cell = 0; cell < kMatrixElements; ++cell) {
            // Preserve the exact operation order of cell * 0.0001 * value.
            const double scaled_cell = matrix_values[cell] * 0.0001;
            for (std::size_t nibble = 0; nibble < kNibbleValues; ++nibble) {
                cheap_table[cell * kNibbleValues + nibble] =
                    scaled_cell * static_cast<double>(nibble);
            }
        }
        check_cuda_header80(
            cudaMemcpy(device_cheap_table_, cheap_table.data(),
                       kCheapTableElements * sizeof(double), cudaMemcpyHostToDevice),
            "cudaMemcpy(header80 cheap matrix table)");
#endif'''
    text = replace_once(text, old_upload, new_upload, "matrix-cache upload")

    text = replace_once(
        text,
        '''    header80_pow_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<DeviceShareResult*>(device_result_),
        count);''',
        '''    header80_pow_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_cheap_table_),
        static_cast<DeviceShareResult*>(device_result_),
        count);''',
        "kernel cache launch",
    )

    required = (
        "PEPEPOW_CUDA_CHEAP_LUT",
        "PEPEPOW_CUDA_BYTE_UNROLL",
        "kCheapTableElements",
        "device_cheap_table_",
        "cudaMemcpy(header80 cheap matrix table)",
    )
    for marker in required:
        if marker not in text:
            raise SystemExit(f"v0.4.1 CUDA source missing marker: {marker}")
    CUDA.write_text(text, encoding="utf-8")


if __name__ == "__main__":
    apply_v040_profile()
    prepare_main()
    prepare_header()
    prepare_cmake()
    prepare_validation()
    prepare_cuda()
    print("PASS: v0.4.1 matrix-cache source profile applied")
