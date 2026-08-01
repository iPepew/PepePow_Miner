#!/usr/bin/env python3
"""Apply the v0.5.5 interleaved-nonce CUDA performance profile."""
from __future__ import annotations

from pathlib import Path
import runpy

ROOT = Path(__file__).resolve().parents[1]
VERSION_FILE = ROOT / "VERSION"
MAIN = ROOT / "native/src/app/main.cpp"
CMAKE = ROOT / "native/CMakeLists.txt"
H_RUN = ROOT / "hiveos/h-run.sh"
V054 = ROOT / "native/src/cuda/header80_backend_v054.cu"
V055 = ROOT / "native/src/cuda/header80_backend_v055.cu"


def replace_once(text: str, old: str, new: str, label: str) -> str:
    if new in text:
        return text
    if old not in text:
        raise SystemExit(f"v0.5.5 source preparation failed: {label}")
    return text.replace(old, new, 1)


def apply_v054_profile() -> None:
    runpy.run_path(str(ROOT / "hiveos/prepare-v054-source.py"), run_name="__main__")


def prepare_version() -> None:
    VERSION_FILE.write_text("0.5.5-PR\n", encoding="utf-8")


def prepare_main() -> None:
    text = MAIN.read_text(encoding="utf-8")
    text = replace_once(
        text,
        'return std::string("PepeW Lookup Split Edition ") + PEPEPOW_VERSION +',
        'return std::string("PepeW ILP Edition ") + PEPEPOW_VERSION +',
        "build identity",
    )
    text = replace_once(
        text,
        '                  "pipeline=autotune exact_bit_conversions=1 "\n'
        '                  "bit_sw_fraction=1 scaled_nibble_table=autotune "\n'
        '                  "assume_finite=autotune hashmod_hoist=1 "\n'
        '                  "scaled_matrix=1 upload_cache=1 prefer_l1=1");',
        '                  "pipeline=autotune exact_bit_conversions=1 "\n'
        '                  "bit_sw_fraction=1 scaled_nibble_table=1 "\n'
        '                  "assume_finite=1 ilp_nonces=autotune "\n'
        '                  "hashmod_hoist=1 scaled_matrix=1 upload_cache=1 prefer_l1=1");',
        "v0.5.5 runtime markers",
    )
    MAIN.write_text(text, encoding="utf-8")


def prepare_cmake() -> None:
    text = CMAKE.read_text(encoding="utf-8")
    option_marker = 'option(PEPEPOW_CUDA_ASSUME_FINITE "Skip unreachable non-finite retry loop for bounded HooHash inputs" OFF)\n'
    text = replace_once(
        text,
        option_marker,
        option_marker
        + 'set(PEPEPOW_CUDA_ILP_NONCES "1" CACHE STRING "Independent nonces interleaved by each split HooHash thread")\n'
        + 'if(NOT PEPEPOW_CUDA_ILP_NONCES MATCHES "^[1-4]$")\n'
        + '    message(FATAL_ERROR "PEPEPOW_CUDA_ILP_NONCES must be 1, 2, 3 or 4")\n'
        + 'endif()\n',
        "ILP CMake option",
    )
    text = replace_once(
        text,
        '        src/cuda/header80_backend_v054.cu\n',
        '        src/cuda/header80_backend_v055.cu\n',
        "v0.5.5 backend selection",
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
        + '    target_compile_definitions(pepepow_cuda PRIVATE PEPEPOW_CUDA_ILP_NONCES=${PEPEPOW_CUDA_ILP_NONCES})\n',
        "ILP compile definition",
    )
    CMAKE.write_text(text, encoding="utf-8")


def prepare_hive_run() -> None:
    text = H_RUN.read_text(encoding="utf-8")
    text = text.replace(
        "AUTOTUNED_PIPELINE EXACT_BIT_CONVERSIONS BIT_SW_FRACTION SCALED_NIBBLE_TABLE ASSUME_FINITE HASHMOD_HOIST PREFER_L1",
        "AUTOTUNED_PIPELINE EXACT_BIT_CONVERSIONS BIT_SW_FRACTION SCALED_NIBBLE_TABLE ASSUME_FINITE ILP_NONCES HASHMOD_HOIST PREFER_L1",
    )
    text = text.replace(
        "autotuned monolithic/split pipeline; exact bit conversions; direct bit fraction(sum/1024); optional cell-major scaled-nibble lookup; finite-domain nonlinear fast path; hash-mod conversion hoist; PreferL1; persistent buffers; 524288 runtime batch",
        "autotuned ILP split pipeline; exact bit conversions; direct bit fraction(sum/1024); cell-major scaled-nibble lookup; finite-domain nonlinear fast path; interleaved independent nonces; hash-mod conversion hoist; PreferL1; persistent buffers; 524288 runtime batch",
    )
    H_RUN.write_text(text, encoding="utf-8")


def prepare_cuda() -> None:
    text = V054.read_text(encoding="utf-8")
    text = replace_once(
        text,
        '#ifndef PEPEPOW_CUDA_ASSUME_FINITE\n#define PEPEPOW_CUDA_ASSUME_FINITE 0\n#endif\n',
        '#ifndef PEPEPOW_CUDA_ASSUME_FINITE\n#define PEPEPOW_CUDA_ASSUME_FINITE 0\n#endif\n'
        '#ifndef PEPEPOW_CUDA_ILP_NONCES\n#define PEPEPOW_CUDA_ILP_NONCES 1\n#endif\n',
        "ILP CUDA macro",
    )

    anchor = '''__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void header80_first_kernel('''
    ilp_code = r'''template <int ILP>
__device__ __forceinline__ void matrix_row_ilp(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    int row,
    const std::uint32_t first_pass[ILP][8],
    const double hash_mod_fp64[ILP],
    const double nonce_mod[ILP],
    double sw[ILP],
    double sums[ILP]) {
    #pragma unroll
    for (int lane = 0; lane < ILP; ++lane) sums[lane] = 0.0;
    const int row_offset = row * 64;
    #pragma unroll 1
    for (int word_index = 0; word_index < 8; ++word_index) {
        std::uint32_t packed_words[ILP];
        #pragma unroll
        for (int lane = 0; lane < ILP; ++lane) {
            packed_words[lane] = first_pass[lane][word_index];
        }
        #pragma unroll
        for (int byte_in_word = 0; byte_in_word < 4; ++byte_in_word) {
            const int byte_index = word_index * 4 + byte_in_word;
            const int high_cell = row_offset + byte_index * 2;
            std::uint32_t high[ILP];
            std::uint32_t low[ILP];
            #pragma unroll
            for (int lane = 0; lane < ILP; ++lane) {
                const std::uint8_t packed = static_cast<std::uint8_t>(
                    packed_words[lane] >> static_cast<unsigned int>(byte_in_word * 8));
                high[lane] = static_cast<std::uint32_t>(packed >> 4U);
                low[lane] = static_cast<std::uint32_t>(packed & 0x0fU);
                accumulate(matrix, scaled_nibble_table, high_cell, high[lane],
                           nibble_to_double(high[lane]), hash_mod_fp64[lane],
                           nonce_mod[lane], sums[lane], sw[lane]);
            }
            #pragma unroll
            for (int lane = 0; lane < ILP; ++lane) {
                accumulate(matrix, scaled_nibble_table, high_cell + 1, low[lane],
                           nibble_to_double(low[lane]), hash_mod_fp64[lane],
                           nonce_mod[lane], sums[lane], sw[lane]);
            }
        }
    }
}

template <int ILP>
__device__ __forceinline__ void hoohash_mix_words_ilp(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    const std::uint32_t mix_nonce[ILP],
    const std::uint32_t first_pass[ILP][8],
    std::uint32_t mixed[ILP][8]) {
    double hash_mod_fp64[ILP];
    double nonce_mod[ILP];
    double sw[ILP];
    #pragma unroll
    for (int lane = 0; lane < ILP; ++lane) {
        std::uint32_t hash_xor = 0;
        #pragma unroll
        for (int i = 0; i < 8; ++i) {
            hash_xor ^= first_pass[lane][i];
            mixed[lane][i] = first_pass[lane][i];
        }
        hash_mod_fp64[lane] = u32_to_double_exact(byte_swap32(hash_xor));
        nonce_mod[lane] = u32_to_double_exact(mix_nonce[lane] & 0xffU);
        sw[lane] = 0.0;
    }
    #pragma unroll 1
    for (int pair = 0; pair < 32; ++pair) {
        double even_sum[ILP];
        double odd_sum[ILP];
        matrix_row_ilp<ILP>(matrix, scaled_nibble_table, pair * 2, first_pass,
                            hash_mod_fp64, nonce_mod, sw, even_sum);
        matrix_row_ilp<ILP>(matrix, scaled_nibble_table, pair * 2 + 1, first_pass,
                            hash_mod_fp64, nonce_mod, sw, odd_sum);
        #pragma unroll
        for (int lane = 0; lane < ILP; ++lane) {
            const std::uint64_t combined = positive_double_to_u64_rz(even_sum[lane]) +
                                           positive_double_to_u64_rz(odd_sum[lane]);
            const std::uint32_t shift = static_cast<std::uint32_t>((pair & 3) * 8);
            mixed[lane][pair >> 2] ^=
                static_cast<std::uint32_t>(combined & 0xffU) << shift;
        }
    }
}

#if PEPEPOW_CUDA_ILP_NONCES > 1
template <int ILP>
__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void hoohash_mix_kernel_ilp(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    std::uint32_t* __restrict__ work_words,
    std::size_t count) {
    const std::size_t worker =
        static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    const std::size_t base = worker * static_cast<std::size_t>(ILP);
    if (base >= count) return;

    std::uint32_t mix_nonce[ILP];
    std::uint32_t first_pass[ILP][8];
    std::uint32_t mixed[ILP][8];
    #pragma unroll
    for (int lane = 0; lane < ILP; ++lane) {
        const std::size_t index = base + static_cast<std::size_t>(lane);
        const bool valid = index < count;
        const std::uint32_t nonce = first_nonce + static_cast<std::uint32_t>(index);
        mix_nonce[lane] = byte_swap32(nonce);
        const std::uint32_t* input = work_words + index * 8U;
        #pragma unroll
        for (int i = 0; i < 8; ++i) first_pass[lane][i] = valid ? input[i] : 0U;
    }

    hoohash_mix_words_ilp<ILP>(matrix, scaled_nibble_table, mix_nonce,
                               first_pass, mixed);

    #pragma unroll
    for (int lane = 0; lane < ILP; ++lane) {
        const std::size_t index = base + static_cast<std::size_t>(lane);
        if (index >= count) continue;
        std::uint32_t* output = work_words + index * 8U;
        #pragma unroll
        for (int i = 0; i < 8; ++i) output[i] = mixed[lane][i];
    }
}
#endif

'''
    text = replace_once(text, anchor, ilp_code + anchor, "ILP device pipeline")

    text = replace_once(
        text,
        'std::string_view Header80CudaBackend::name() const noexcept { return "cuda-header80-split-pipeline"; }',
        'std::string_view Header80CudaBackend::name() const noexcept { return PEPEPOW_CUDA_ILP_NONCES > 1 ? "cuda-header80-split-ilp-pipeline" : "cuda-header80-split-pipeline"; }',
        "ILP backend name",
    )

    old_launch = '''    static thread_local bool cache_configured = false;
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
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_), work_words, count);
    check_cuda_header80(cudaGetLastError(), "hoohash_mix_kernel launch");
    header80_final_kernel<<<blocks, threads>>>(
'''
    new_launch = '''    static thread_local bool cache_configured = false;
    if (!cache_configured) {
#if PEPEPOW_CUDA_ILP_NONCES > 1
        check_cuda_header80(
            cudaFuncSetCacheConfig(
                hoohash_mix_kernel_ilp<PEPEPOW_CUDA_ILP_NONCES>,
                cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(hoohash mix ILP)");
#else
        check_cuda_header80(
            cudaFuncSetCacheConfig(hoohash_mix_kernel, cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(hoohash mix)");
#endif
        cache_configured = true;
    }
    auto* work_words = static_cast<std::uint32_t*>(device_work_);
    header80_first_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin), work_words, count);
    check_cuda_header80(cudaGetLastError(), "header80_first_kernel launch");
#if PEPEPOW_CUDA_ILP_NONCES > 1
    constexpr std::size_t ilp = static_cast<std::size_t>(PEPEPOW_CUDA_ILP_NONCES);
    const unsigned int mix_blocks = static_cast<unsigned int>(
        (count + static_cast<std::size_t>(threads) * ilp - 1U) /
        (static_cast<std::size_t>(threads) * ilp));
    hoohash_mix_kernel_ilp<PEPEPOW_CUDA_ILP_NONCES><<<mix_blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_), work_words, count);
    check_cuda_header80(cudaGetLastError(), "hoohash_mix_kernel_ilp launch");
#else
    hoohash_mix_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_), work_words, count);
    check_cuda_header80(cudaGetLastError(), "hoohash_mix_kernel launch");
#endif
    header80_final_kernel<<<blocks, threads>>>(
'''
    text = replace_once(text, old_launch, new_launch, "ILP split launch")
    V055.write_text(text, encoding="utf-8")


def verify() -> None:
    checks = {
        VERSION_FILE: ["0.5.5-PR"],
        MAIN: ["PepeW ILP Edition", "ilp_nonces=autotune"],
        CMAKE: ["header80_backend_v055.cu", "PEPEPOW_CUDA_ILP_NONCES"],
        V055: ["matrix_row_ilp", "hoohash_mix_kernel_ilp", "mix_blocks"],
        H_RUN: ["ILP_NONCES", "interleaved independent nonces"],
    }
    for path, markers in checks.items():
        text = path.read_text(encoding="utf-8")
        for marker in markers:
            if marker not in text:
                raise SystemExit(f"v0.5.5 source missing marker in {path.name}: {marker}")


def main() -> None:
    apply_v054_profile()
    prepare_version()
    prepare_main()
    prepare_cmake()
    prepare_hive_run()
    prepare_cuda()
    verify()
    print("PASS: v0.5.5 ILP source profile applied")


if __name__ == "__main__":
    main()
