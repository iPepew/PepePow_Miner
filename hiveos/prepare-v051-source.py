#!/usr/bin/env python3
"""Apply the v0.5.1 split-kernel performance profile.

The profile starts from the validated v0.5.0 word pipeline, then separates the
integer BLAKE3 stages from the FP64 HooHash stage so the hot matrix kernel can
use fewer registers and higher occupancy. It also adds an exact positive
fraction path based on round-toward-zero conversion, wider RTX 3080 launch
profiles, a 348,160-nonce runtime batch, and 1,024 deterministic CPU/CUDA
consensus samples. The script is idempotent.
"""

from __future__ import annotations

from pathlib import Path
import runpy

ROOT = Path(__file__).resolve().parents[1]
MAIN = ROOT / "native/src/app/main.cpp"
HEADER = ROOT / "native/include/pepepow/cuda/header80_backend.hpp"
CMAKE = ROOT / "native/CMakeLists.txt"
VALIDATION = ROOT / "native/tests/cuda_header80_validation.cpp"
V050 = ROOT / "native/src/cuda/header80_backend_v050.cu"
V051 = ROOT / "native/src/cuda/header80_backend_v051.cu"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"v0.5.1 source preparation failed: {label}")
    return text.replace(old, new, 1)


def apply_v050_profile() -> None:
    runpy.run_path(str(ROOT / "hiveos/prepare-v050-source.py"), run_name="__main__")


def prepare_main() -> None:
    text = MAIN.read_text(encoding="utf-8")
    text = replace_once(
        text,
        'return std::string("PepeW Warp Pipeline Edition ") + PEPEPOW_VERSION +',
        'return std::string("PepeW Split Pipeline Edition ") + PEPEPOW_VERSION +',
        "build identity",
    )
    text = replace_once(
        text,
        '        // 524K restores the higher-throughput launch profile. At the measured\n'
        '        // rate it still keeps clean-job switch latency below one second.\n'
        '        constexpr std::uint64_t chunk_size = 524288;',
        '        // 348,160 nonces matches the 320-thread/1,088-block RTX 3080\n'
        '        // performance profile while keeping clean-job latency low.\n'
        '        constexpr std::uint64_t chunk_size = 348160;',
        "runtime batch",
    )
    text = replace_once(
        text,
        '                  "batch=524288 gpu_stats=per_device word_pipeline=1 "\n'
        '                  "scaled_matrix=autotune upload_cache=1");',
        '                  "batch=348160 gpu_stats=per_device word_pipeline=1 "\n'
        '                  "split_pipeline=autotune fast_fraction=autotune "\n'
        '                  "scaled_matrix=1 upload_cache=1 prefer_l1=1");',
        "v0.5.1 runtime markers",
    )
    MAIN.write_text(text, encoding="utf-8")


def prepare_header() -> None:
    text = HEADER.read_text(encoding="utf-8")
    text = replace_once(
        text,
        '#include "pepepow/core/backend.hpp"\n',
        '#include "pepepow/core/backend.hpp"\n\n#include <cstddef>\n',
        "size type include",
    )
    text = replace_once(
        text,
        '    void* device_matrix_{nullptr};\n',
        '    void* device_matrix_{nullptr};\n'
        '    void* device_work_{nullptr};\n'
        '    std::size_t device_work_capacity_{0};\n',
        "split-pipeline work buffer",
    )
    HEADER.write_text(text, encoding="utf-8")


def prepare_cmake() -> None:
    text = CMAKE.read_text(encoding="utf-8")
    text = replace_once(
        text,
        'set(PEPEPOW_CUDA_BYTE_UNROLL "1" CACHE STRING "HooHash byte-loop unroll factor")\n',
        'set(PEPEPOW_CUDA_BYTE_UNROLL "1" CACHE STRING "HooHash word-loop unroll factor")\n'
        'option(PEPEPOW_CUDA_SPLIT_PIPELINE "Split BLAKE3 and HooHash into separate kernels" ON)\n'
        'option(PEPEPOW_CUDA_FAST_FRACTION "Use exact positive fraction conversion path" ON)\n',
        "v0.5.1 CUDA options",
    )
    text = replace_once(
        text,
        '    if(NOT PEPEPOW_CUDA_THREADS MATCHES "^(64|128|256)$")\n'
        '        message(FATAL_ERROR "PEPEPOW_CUDA_THREADS must be 64, 128 or 256")\n'
        '    endif()\n',
        '    if(NOT PEPEPOW_CUDA_THREADS MATCHES "^(64|128|256|320|384)$")\n'
        '        message(FATAL_ERROR "PEPEPOW_CUDA_THREADS must be 64, 128, 256, 320 or 384")\n'
        '    endif()\n',
        "RTX 3080 launch widths",
    )
    text = replace_once(
        text,
        '        src/cuda/header80_backend_v050.cu\n',
        '        src/cuda/header80_backend_v051.cu\n',
        "split-pipeline backend selection",
    )
    text = replace_once(
        text,
        '        PEPEPOW_CUDA_BYTE_UNROLL=${PEPEPOW_CUDA_BYTE_UNROLL})\n',
        '        PEPEPOW_CUDA_BYTE_UNROLL=${PEPEPOW_CUDA_BYTE_UNROLL})\n'
        '    if(PEPEPOW_CUDA_SPLIT_PIPELINE)\n'
        '        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_SPLIT_PIPELINE=1)\n'
        '    else()\n'
        '        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_SPLIT_PIPELINE=0)\n'
        '    endif()\n'
        '    if(PEPEPOW_CUDA_FAST_FRACTION)\n'
        '        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_FAST_FRACTION=1)\n'
        '    else()\n'
        '        target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_FAST_FRACTION=0)\n'
        '    endif()\n',
        "split-pipeline compile definitions",
    )
    CMAKE.write_text(text, encoding="utf-8")


def prepare_validation() -> None:
    text = VALIDATION.read_text(encoding="utf-8")
    text = text.replace('sample < 512U', 'sample < 1024U')
    text = text.replace(
        'PASS: 512 word-pipeline CPU/CUDA samples match',
        'PASS: 1024 split-pipeline CPU/CUDA samples match',
    )
    if 'sample < 1024U' not in text or 'PASS: 1024 split-pipeline CPU/CUDA samples match' not in text:
        raise SystemExit("v0.5.1 source preparation failed: validation expansion")
    VALIDATION.write_text(text, encoding="utf-8")


def prepare_cuda() -> None:
    text = V050.read_text(encoding="utf-8")

    text = replace_once(
        text,
        '#ifndef PEPEPOW_CUDA_BYTE_UNROLL\n#define PEPEPOW_CUDA_BYTE_UNROLL 1\n#endif\n',
        '#ifndef PEPEPOW_CUDA_BYTE_UNROLL\n#define PEPEPOW_CUDA_BYTE_UNROLL 1\n#endif\n'
        '#ifndef PEPEPOW_CUDA_SPLIT_PIPELINE\n#define PEPEPOW_CUDA_SPLIT_PIPELINE 1\n#endif\n'
        '#ifndef PEPEPOW_CUDA_FAST_FRACTION\n#define PEPEPOW_CUDA_FAST_FRACTION 1\n#endif\n',
        "split-pipeline macros",
    )

    text = replace_once(
        text,
        '__device__ __forceinline__ double nonlinear(double x) {\n',
        '__device__ __forceinline__ double positive_fraction(double value) {\n'
        '#if PEPEPOW_CUDA_FAST_FRACTION\n'
        '    // All HooHash inputs are non-negative. Below 2^52, conversion with\n'
        '    // round-toward-zero is exactly floor(); at and above 2^52 every FP64\n'
        '    // value is integral. This preserves consensus while avoiding floor().\n'
        '    if (value >= 0x1.0p52) return 0.0;\n'
        '    return value - static_cast<double>(__double2ull_rz(value));\n'
        '#else\n'
        '    return value - floor(value);\n'
        '#endif\n'
        '}\n\n'
        '__device__ __forceinline__ double nonlinear(double x) {\n',
        "exact positive fraction helper",
    )
    text = text.replace(
        '    const double one = one_base - floor(one_base);\n'
        '    const double two = two_base - floor(two_base);',
        '    const double one = positive_fraction(one_base);\n'
        '    const double two = positive_fraction(two_base);',
    )
    text = text.replace(
        '    sw = sum / 1024.0 - floor(sum / 1024.0);',
        '    sw = positive_fraction(sum / 1024.0);',
    )

    old_matrix_row = '''__device__ __forceinline__ double matrix_row(
    const double* __restrict__ matrix,
    int row, const std::uint32_t first_pass[8], std::uint32_t hash_mod,
    double nonce_mod, double& sw) {
    double sum = 0.0;
    const double hash_mod_fp64 = static_cast<double>(hash_mod);
    const int row_offset = row * 64;
#if PEPEPOW_CUDA_BYTE_UNROLL == 4
    #pragma unroll 4
#elif PEPEPOW_CUDA_BYTE_UNROLL == 2
    #pragma unroll 2
#else
    #pragma unroll 1
#endif
    for (int byte_index = 0; byte_index < 32; ++byte_index) {
        const std::uint8_t packed = word_byte(first_pass, byte_index);
        const int high_cell = row_offset + byte_index * 2;
        const int low_cell = high_cell + 1;
        accumulate(matrix, high_cell, static_cast<double>(packed >> 4U),
                   hash_mod_fp64, nonce_mod, sum, sw);
        accumulate(matrix, low_cell, static_cast<double>(packed & 0x0fU),
                   hash_mod_fp64, nonce_mod, sum, sw);
    }
    return sum;
}
'''
    new_matrix_row = '''__device__ __forceinline__ double matrix_row(
    const double* __restrict__ matrix,
    int row, const std::uint32_t first_pass[8], std::uint32_t hash_mod,
    double nonce_mod, double& sw) {
    double sum = 0.0;
    const double hash_mod_fp64 = static_cast<double>(hash_mod);
    const int row_offset = row * 64;
#if PEPEPOW_CUDA_BYTE_UNROLL == 4
    #pragma unroll 4
#elif PEPEPOW_CUDA_BYTE_UNROLL == 2
    #pragma unroll 2
#else
    #pragma unroll 1
#endif
    for (int word_index = 0; word_index < 8; ++word_index) {
        const std::uint32_t packed_word = first_pass[word_index];
        #pragma unroll
        for (int byte_in_word = 0; byte_in_word < 4; ++byte_in_word) {
            const int byte_index = word_index * 4 + byte_in_word;
            const std::uint8_t packed = static_cast<std::uint8_t>(
                packed_word >> static_cast<unsigned int>(byte_in_word * 8));
            const int high_cell = row_offset + byte_index * 2;
            accumulate(matrix, high_cell, static_cast<double>(packed >> 4U),
                       hash_mod_fp64, nonce_mod, sum, sw);
            accumulate(matrix, high_cell + 1, static_cast<double>(packed & 0x0fU),
                       hash_mod_fp64, nonce_mod, sum, sw);
        }
    }
    return sum;
}
'''
    text = replace_once(text, old_matrix_row, new_matrix_row, "word-grouped matrix row")

    kernel_start = text.index('__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)\nvoid header80_pow_kernel(')
    kernel_end = text.index('\n\n} // namespace', kernel_start)
    new_kernels = r'''__device__ __forceinline__ void hoohash_mix_words(
    const double* __restrict__ matrix,
    std::uint32_t mix_nonce,
    const std::uint32_t first_pass[8],
    std::uint32_t mixed[8]) {
    std::uint32_t hash_xor = 0;
    #pragma unroll
    for (int i = 0; i < 8; ++i) {
        hash_xor ^= first_pass[i];
        mixed[i] = first_pass[i];
    }
    const std::uint32_t hash_mod = byte_swap32(hash_xor);
    const double nonce_mod = static_cast<double>(mix_nonce & 0xffU);
    double sw = 0.0;
    #pragma unroll 1
    for (int pair = 0; pair < 32; ++pair) {
        const double even_sum = matrix_row(matrix, pair * 2, first_pass, hash_mod, nonce_mod, sw);
        const double odd_sum = matrix_row(matrix, pair * 2 + 1, first_pass, hash_mod, nonce_mod, sw);
        const std::uint64_t combined = static_cast<std::uint64_t>(even_sum) +
                                       static_cast<std::uint64_t>(odd_sum);
        const std::uint32_t shift = static_cast<std::uint32_t>((pair & 3) * 8);
        mixed[pair >> 2] ^= static_cast<std::uint32_t>(combined & 0xffU) << shift;
    }
}

__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void header80_first_kernel(
    std::uint32_t first_nonce,
    std::uint32_t* __restrict__ work_words,
    std::size_t count) {
    const std::size_t index = static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) return;
    std::uint32_t first_pass[8];
    blake3_header80_words(first_nonce + static_cast<std::uint32_t>(index), first_pass);
    std::uint32_t* output = work_words + index * 8U;
    #pragma unroll
    for (int i = 0; i < 8; ++i) output[i] = first_pass[i];
}

__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void hoohash_mix_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    std::uint32_t* __restrict__ work_words,
    std::size_t count) {
    const std::size_t index = static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) return;
    const std::uint32_t nonce = first_nonce + static_cast<std::uint32_t>(index);
    const std::uint32_t mix_nonce = byte_swap32(nonce);
    const std::uint32_t* input = work_words + index * 8U;
    std::uint32_t first_pass[8];
    std::uint32_t mixed[8];
    #pragma unroll
    for (int i = 0; i < 8; ++i) first_pass[i] = input[i];
    hoohash_mix_words(matrix, mix_nonce, first_pass, mixed);
    std::uint32_t* output = work_words + index * 8U;
    #pragma unroll
    for (int i = 0; i < 8; ++i) output[i] = mixed[i];
}

__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void header80_final_kernel(
    std::uint32_t first_nonce,
    const std::uint32_t* __restrict__ work_words,
    DeviceShareResult* __restrict__ result,
    std::size_t count) {
    const std::size_t index = static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) return;
    const std::uint32_t* input = work_words + index * 8U;
    std::uint32_t mixed[8];
    std::uint32_t final_hash[8];
    #pragma unroll
    for (int i = 0; i < 8; ++i) mixed[i] = input[i];
    blake3_32_words(mixed, final_hash);
    if (!hash_words_meet_target(final_hash)) return;
    if (atomicCAS(&result->found, 0U, 1U) == 0U) {
        result->nonce = first_nonce + static_cast<std::uint32_t>(index);
        #pragma unroll
        for (int i = 0; i < 8; ++i) result->hash_words[i] = final_hash[i];
    }
}

__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void header80_pow_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    DeviceShareResult* __restrict__ result,
    std::size_t count) {
    const std::size_t index = static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    if (index >= count) return;
    const std::uint32_t nonce = first_nonce + static_cast<std::uint32_t>(index);
    std::uint32_t first_pass[8];
    std::uint32_t mixed[8];
    std::uint32_t final_hash[8];
    blake3_header80_words(nonce, first_pass);
    hoohash_mix_words(matrix, byte_swap32(nonce), first_pass, mixed);
    blake3_32_words(mixed, final_hash);
    if (!hash_words_meet_target(final_hash)) return;
    if (atomicCAS(&result->found, 0U, 1U) == 0U) {
        result->nonce = nonce;
        #pragma unroll
        for (int i = 0; i < 8; ++i) result->hash_words[i] = final_hash[i];
    }
}'''
    text = text[:kernel_start] + new_kernels + text[kernel_end:]

    text = replace_once(
        text,
        '    if (device_result_ != nullptr || device_matrix_ != nullptr) {\n',
        '    if (device_result_ != nullptr || device_matrix_ != nullptr || device_work_ != nullptr) {\n',
        "destructor device selection",
    )
    text = replace_once(
        text,
        '    if (device_matrix_ != nullptr) {\n'
        '        cudaFree(device_matrix_);\n'
        '        device_matrix_ = nullptr;\n'
        '    }\n',
        '    if (device_matrix_ != nullptr) {\n'
        '        cudaFree(device_matrix_);\n'
        '        device_matrix_ = nullptr;\n'
        '    }\n'
        '    if (device_work_ != nullptr) {\n'
        '        cudaFree(device_work_);\n'
        '        device_work_ = nullptr;\n'
        '        device_work_capacity_ = 0;\n'
        '    }\n',
        "work-buffer cleanup",
    )
    text = replace_once(
        text,
        'std::string_view Header80CudaBackend::name() const noexcept { return "cuda-header80-word-pipeline"; }',
        '#if PEPEPOW_CUDA_SPLIT_PIPELINE\n'
        'std::string_view Header80CudaBackend::name() const noexcept { return "cuda-header80-split-pipeline"; }\n'
        '#else\n'
        'std::string_view Header80CudaBackend::name() const noexcept { return "cuda-header80-monolithic-pipeline"; }\n'
        '#endif',
        "backend identity",
    )

    old_launch = '''    if (device_result_ == nullptr) {
        check_cuda_header80(cudaMalloc(&device_result_, sizeof(DeviceShareResult)),
                            "cudaMalloc(header80 result)");
    }
    check_cuda_header80(cudaMemset(device_result_, 0, sizeof(std::uint32_t)),
                        "cudaMemset(header80 found flag)");

    constexpr unsigned int threads = static_cast<unsigned int>(PEPEPOW_CUDA_THREADS);
    const unsigned int blocks = static_cast<unsigned int>((count + threads - 1U) / threads);
    header80_pow_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<DeviceShareResult*>(device_result_),
        count);
    check_cuda_header80(cudaGetLastError(), "header80_pow_kernel launch");

    DeviceShareResult host_result{};
'''
    new_launch = '''    if (device_result_ == nullptr) {
        check_cuda_header80(cudaMalloc(&device_result_, sizeof(DeviceShareResult)),
                            "cudaMalloc(header80 result)");
    }
    check_cuda_header80(cudaMemset(device_result_, 0, sizeof(std::uint32_t)),
                        "cudaMemset(header80 found flag)");

    constexpr unsigned int threads = static_cast<unsigned int>(PEPEPOW_CUDA_THREADS);
    const unsigned int blocks = static_cast<unsigned int>((count + threads - 1U) / threads);

#if PEPEPOW_CUDA_SPLIT_PIPELINE
    if (device_work_ == nullptr || device_work_capacity_ < count) {
        if (device_work_ != nullptr) {
            check_cuda_header80(cudaFree(device_work_), "cudaFree(header80 work resize)");
        }
        check_cuda_header80(
            cudaMalloc(&device_work_, count * 8U * sizeof(std::uint32_t)),
            "cudaMalloc(header80 split work)");
        device_work_capacity_ = count;
    }
    static thread_local bool cache_configured = false;
    if (!cache_configured) {
        check_cuda_header80(
            cudaFuncSetCacheConfig(hoohash_mix_kernel, cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(hoohash mix)");
        cache_configured = true;
    }
    auto* work_words = static_cast<std::uint32_t*>(device_work_);
    header80_first_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin), work_words, count);
    check_cuda_header80(cudaGetLastError(), "header80_first_kernel launch");
    hoohash_mix_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_), work_words, count);
    check_cuda_header80(cudaGetLastError(), "hoohash_mix_kernel launch");
    header80_final_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin), work_words,
        static_cast<DeviceShareResult*>(device_result_), count);
    check_cuda_header80(cudaGetLastError(), "header80_final_kernel launch");
#else
    static thread_local bool cache_configured = false;
    if (!cache_configured) {
        check_cuda_header80(
            cudaFuncSetCacheConfig(header80_pow_kernel, cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(header80 monolithic)");
        cache_configured = true;
    }
    header80_pow_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<DeviceShareResult*>(device_result_), count);
    check_cuda_header80(cudaGetLastError(), "header80_pow_kernel launch");
#endif

    DeviceShareResult host_result{};
'''
    text = replace_once(text, old_launch, new_launch, "split-pipeline host launches")

    for marker in (
        'positive_fraction',
        'header80_first_kernel',
        'hoohash_mix_kernel',
        'header80_final_kernel',
        'device_work_capacity_',
        'cudaFuncCachePreferL1',
    ):
        if marker not in text:
            raise SystemExit(f"v0.5.1 CUDA source missing marker: {marker}")
    V051.write_text(text, encoding="utf-8")


def already_prepared() -> bool:
    return (
        V051.exists()
        and "PepeW Split Pipeline Edition" in MAIN.read_text(encoding="utf-8")
        and "header80_backend_v051.cu" in CMAKE.read_text(encoding="utf-8")
        and "device_work_capacity_" in HEADER.read_text(encoding="utf-8")
    )


if __name__ == "__main__":
    if not already_prepared():
        apply_v050_profile()
        prepare_main()
        prepare_header()
        prepare_cmake()
        prepare_validation()
        prepare_cuda()

    required = {
        MAIN: (
            "PepeW Split Pipeline Edition",
            "https://t.me/pepepow_ru",
            "chunk_size = 348160",
            "split_pipeline=autotune",
        ),
        HEADER: ("device_work_", "device_work_capacity_"),
        CMAKE: (
            "header80_backend_v051.cu",
            "PEPEPOW_CUDA_SPLIT_PIPELINE",
            "PEPEPOW_CUDA_FAST_FRACTION",
            "320|384",
        ),
        VALIDATION: ("PASS: 1024 split-pipeline CPU/CUDA samples match",),
        V051: (
            "header80_first_kernel",
            "hoohash_mix_kernel",
            "header80_final_kernel",
            "positive_fraction",
            "cudaFuncCachePreferL1",
        ),
    }
    for path, markers in required.items():
        value = path.read_text(encoding="utf-8")
        for marker in markers:
            if marker not in value:
                raise SystemExit(f"v0.5.1 source missing marker in {path.name}: {marker}")

    print("PASS: v0.5.1 split-pipeline source profile applied")
