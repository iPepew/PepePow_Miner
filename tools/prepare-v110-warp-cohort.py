from pathlib import Path
import runpy

# Start from the proven v1.0.9 exact service geometry. v1.1.0 keeps that
# kernel as a fail-safe baseline and adds a second, fundamentally different
# Volta execution model: a persistent warp-cohort state machine.
runpy.run_path('tools/prepare-v109-volta-geometry.py', run_name='__main__')

p6 = Path('native/src/cuda/v1/header80_backend_part06.inc')
t6 = p6.read_text(encoding='utf-8')
namespace_end = '\n\n} // namespace\n'
if namespace_end not in t6:
    raise SystemExit('anonymous namespace end marker missing')

cohort_code = r'''

// v1.1.0 persistent warp-cohort engine --------------------------------------
//
// Direct per-thread HooHash on V100 proved that sparse nonlinear branches are
// too divergent. The service24 engine fixes divergence by compacting tasks,
// but pays two block-wide barriers for every one of the 4096 matrix cells.
//
// The cohort engine uses a third model. Each warp owns 32 independent nonce
// state machines. Warm lanes continue advancing while cold lanes park their
// exact nonlinear input in registers. Once enough lanes are parked, the warp
// evaluates nonlinear work densely. There are no shared queues, no atomics and
// no block-wide barriers in the HooHash hot loop. Delaying a cold operation is
// consensus-safe because that nonce does not advance past its cold cell until
// its own result has been committed.

__device__ __forceinline__ std::uint32_t v110_column_nibble(
    const std::uint32_t first_pass[8], unsigned int column) {
    const int byte_index = static_cast<int>(column >> 1U);
    const std::uint8_t packed = word_byte(first_pass, byte_index);
    return (column & 1U) == 0U
        ? static_cast<std::uint32_t>(packed >> 4U)
        : static_cast<std::uint32_t>(packed & 0x0fU);
}

__device__ __forceinline__ void v110_commit_cell(
    unsigned int& cell_index,
    double& row_sum,
    double& even_sum,
    std::uint32_t mixed[8]) {
    ++cell_index;
    if ((cell_index & 63U) != 0U) return;

    const unsigned int completed_row = (cell_index >> 6U) - 1U;
    if ((completed_row & 1U) == 0U) {
        even_sum = row_sum;
    } else {
        const unsigned int pair = completed_row >> 1U;
        const std::uint64_t combined =
            positive_double_to_u64_rz(even_sum) +
            positive_double_to_u64_rz(row_sum);
        const std::uint32_t shift = (pair & 3U) * 8U;
        mixed[pair >> 2U] ^=
            static_cast<std::uint32_t>(combined & 0xffU) << shift;
    }
    row_sum = 0.0;
}

__device__ __forceinline__ void v110_hoohash_warp_cohort(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    std::uint32_t mix_nonce,
    const std::uint32_t first_pass[8],
    std::uint32_t mixed[8],
    bool lane_active,
    unsigned int cohort_threshold) {
    constexpr unsigned int kFullWarpMask = 0xffffffffU;
    constexpr unsigned int kMatrixCells = 4096U;

    std::uint32_t hash_xor = 0U;
    #pragma unroll
    for (int i = 0; i < 8; ++i) {
        hash_xor ^= first_pass[i];
        mixed[i] = first_pass[i];
    }

    const std::uint32_t hash_mod = byte_swap32(hash_xor);
    const double hash_mod_fp64 = u32_to_double_exact(hash_mod);
    const double nonce_mod = u32_to_double_exact(mix_nonce & 0xffU);
    HooHashSwState sw = initial_sw_state();

    unsigned int cell_index = 0U;
    double row_sum = 0.0;
    double even_sum = 0.0;
    bool waiting = false;
    double pending_x = 0.0;
    double pending_value = 0.0;

    // All 32 lanes remain in the control loop, including inactive tail lanes,
    // so every warp intrinsic always uses one stable mask on Volta independent
    // thread scheduling.
    while (__any_sync(kFullWarpMask, lane_active && cell_index < kMatrixCells)) {
        if (lane_active && cell_index < kMatrixCells && !waiting) {
            const unsigned int column = cell_index & 63U;
            const std::uint32_t nibble =
                v110_column_nibble(first_pass, column);
            const double value = nibble_to_double(nibble);
            const bool cold = sw_state_is_cold(sw);

            if (cold && nibble != 0U) {
                const double cell = matrix[cell_index];
                pending_x = cell * hash_mod_fp64 * value + nonce_mod;
                pending_value = value;
                waiting = true;
            } else {
                if (!cold) {
#if PEPEPOW_CUDA_SCALED_NIBBLE_TABLE
                    row_sum += __ldg(
                        scaled_nibble_table +
                        static_cast<std::size_t>(cell_index) * 16U + nibble);
#elif PEPEPOW_CUDA_SCALED_MATRIX
                    row_sum += kHeader80ScaledMatrix[cell_index] * value;
#else
                    row_sum += matrix[cell_index] * 0.0001 * value;
#endif
                }
                // cold+nibble==0 contributes exactly zero but still advances
                // the SW state, identical to accumulate().
                update_sw_state(sw, row_sum);
                v110_commit_cell(cell_index, row_sum, even_sum, mixed);
            }
        }

        const unsigned int pending_mask = __ballot_sync(
            kFullWarpMask,
            lane_active && cell_index < kMatrixCells && waiting);
        if (pending_mask == 0U) continue;

        const unsigned int runnable_mask = __ballot_sync(
            kFullWarpMask,
            lane_active && cell_index < kMatrixCells && !waiting);
        const unsigned int active_mask = pending_mask | runnable_mask;
        const unsigned int active_count = static_cast<unsigned int>(__popc(active_mask));
        const unsigned int pending_count = static_cast<unsigned int>(__popc(pending_mask));
        const unsigned int target =
            cohort_threshold < active_count ? cohort_threshold : active_count;

        // Service a cohort once it is dense enough, or immediately when every
        // remaining nonce in the warp is parked. Only pending lanes execute
        // safe_nonlinear(), so the per-nonce operation order is unchanged.
        if (pending_count >= target || runnable_mask == 0U) {
            if (lane_active && cell_index < kMatrixCells && waiting) {
                row_sum += safe_nonlinear(pending_x) * pending_value * 1234.0;
                update_sw_state(sw, row_sum);
                waiting = false;
                v110_commit_cell(cell_index, row_sum, even_sum, mixed);
            }
        }
    }
}

__global__ __launch_bounds__(256, 2)
void header80_pow_warp_cohort_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    DeviceShareResult* __restrict__ result,
    std::size_t count,
    unsigned int cohort_threshold) {
    constexpr unsigned int kFullWarpMask = 0xffffffffU;
    const std::size_t global_thread =
        static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    const std::size_t grid_stride =
        static_cast<std::size_t>(gridDim.x) * blockDim.x;

    // A bounded grid persists over several nonce waves when count exceeds the
    // physical grid. Every lane in a warp enters the wave, including tail
    // lanes, which keeps the cohort ballots well-defined.
    for (std::size_t index = global_thread;; index += grid_stride) {
        const bool lane_active = index < count;
        if (__ballot_sync(kFullWarpMask, lane_active) == 0U) break;

        const std::uint32_t nonce =
            first_nonce + static_cast<std::uint32_t>(lane_active ? index : 0U);
        std::uint32_t first_pass[8]{};
        std::uint32_t mixed[8]{};
        std::uint32_t final_hash[8]{};
        if (lane_active) blake3_header80_words(nonce, first_pass);

        v110_hoohash_warp_cohort(
            matrix, scaled_nibble_table, byte_swap32(nonce), first_pass,
            mixed, lane_active, cohort_threshold);

        if (lane_active) {
            blake3_32_words(mixed, final_hash);
            if (hash_words_meet_target(final_hash)) {
                if (atomicCAS(&result->found, 0U, 1U) == 0U) {
                    result->nonce = nonce;
                    #pragma unroll
                    for (int i = 0; i < 8; ++i) {
                        result->hash_words[i] = final_hash[i];
                    }
                }
            }
        }
    }
}
// ---------------------------------------------------------------------------
'''

t6 = t6.replace(namespace_end, cohort_code + namespace_end, 1)
p6.write_text(t6, encoding='utf-8')

p7 = Path('native/src/cuda/v1/header80_backend_part07.inc')
t7 = p7.read_text(encoding='utf-8')
old_geometry = '''    const unsigned int threads = threads_per_block_;
    const unsigned int blocks = static_cast<unsigned int>((count + threads - 1U) / threads);
    const std::size_t dynamic_shared_bytes = cold_service_shared_bytes(threads);
'''
new_geometry = '''    const unsigned int threads = threads_per_block_;
    const unsigned int blocks = static_cast<unsigned int>((count + threads - 1U) / threads);
    const std::size_t dynamic_shared_bytes = cold_service_shared_bytes(threads);

    const char* v110_engine_env = std::getenv("PEPEPOW_V110_ENGINE");
    const bool v110_cohort_engine =
        v110_engine_env != nullptr &&
        std::string_view(v110_engine_env) == "cohort";

    auto v110_env_u32 = [](const char* name, unsigned int fallback,
                           unsigned int minimum, unsigned int maximum) {
        const char* text = std::getenv(name);
        if (text == nullptr || *text == '\0') return fallback;
        try {
            const unsigned long parsed = std::stoul(text);
            if (parsed < minimum || parsed > maximum) {
                throw std::invalid_argument(std::string(name) + " is outside the allowed range");
            }
            return static_cast<unsigned int>(parsed);
        } catch (const std::invalid_argument&) {
            throw;
        } catch (...) {
            throw std::invalid_argument(std::string(name) + " must be an integer");
        }
    };

    const unsigned int v110_cohort_threshold =
        v110_env_u32("PEPEPOW_V110_COHORT_THRESHOLD", 16U, 1U, 32U);
    const unsigned int v110_blocks_per_sm =
        v110_env_u32("PEPEPOW_V110_BLOCKS_PER_SM", 10U, 1U, 32U);
'''
if old_geometry not in t7:
    raise SystemExit('v1.0.9 launch geometry marker missing')
t7 = t7.replace(old_geometry, new_geometry, 1)

old_monolithic = '''    static thread_local bool cache_configured = false;
    if (!cache_configured) {
        check_cuda_header80(
            cudaFuncSetCacheConfig(header80_pow_kernel, cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(header80 monolithic)");
        check_cuda_header80(
            cudaFuncSetAttribute(header80_pow_kernel,
                                 cudaFuncAttributePreferredSharedMemoryCarveout,
                                 cudaSharedmemCarveoutMaxL1),
            "cudaFuncSetAttribute(header80 max L1 carveout)");
        cache_configured = true;
    }
    header80_pow_kernel<<<blocks, threads, dynamic_shared_bytes>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_),
        static_cast<DeviceShareResult*>(device_result_), count);
    check_cuda_header80(cudaGetLastError(), "header80_pow_kernel launch");
'''
new_monolithic = '''    static thread_local bool cache_configured = false;
    if (!cache_configured) {
        check_cuda_header80(
            cudaFuncSetCacheConfig(header80_pow_kernel, cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(header80 exact)");
        check_cuda_header80(
            cudaFuncSetAttribute(header80_pow_kernel,
                                 cudaFuncAttributePreferredSharedMemoryCarveout,
                                 cudaSharedmemCarveoutMaxL1),
            "cudaFuncSetAttribute(header80 exact max L1 carveout)");
        check_cuda_header80(
            cudaFuncSetCacheConfig(header80_pow_warp_cohort_kernel,
                                   cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(header80 cohort)");
        cache_configured = true;
    }

    if (v110_cohort_engine) {
        if (threads > 256U) {
            throw std::invalid_argument(
                "v1.1.0 cohort engine requires PEPEPOW_CUDA_THREADS_RUNTIME <= 256");
        }
        static thread_local int cached_sm_device = -1;
        static thread_local int cached_sm_count = 0;
        if (cached_sm_device != device_index_ || cached_sm_count <= 0) {
            check_cuda_header80(
                cudaDeviceGetAttribute(&cached_sm_count,
                                       cudaDevAttrMultiProcessorCount,
                                       device_index_),
                "cudaDeviceGetAttribute(multiprocessor count)");
            cached_sm_device = device_index_;
        }
        const unsigned int persistent_limit = static_cast<unsigned int>(
            cached_sm_count) * v110_blocks_per_sm;
        const unsigned int cohort_blocks =
            std::max(1U, std::min(blocks, persistent_limit));
        header80_pow_warp_cohort_kernel<<<cohort_blocks, threads>>>(
            static_cast<std::uint32_t>(range.begin),
            static_cast<const double*>(device_matrix_),
            static_cast<const double*>(device_scaled_nibble_),
            static_cast<DeviceShareResult*>(device_result_), count,
            v110_cohort_threshold);
        check_cuda_header80(
            cudaGetLastError(), "header80_pow_warp_cohort_kernel launch");
    } else {
        header80_pow_kernel<<<blocks, threads, dynamic_shared_bytes>>>(
            static_cast<std::uint32_t>(range.begin),
            static_cast<const double*>(device_matrix_),
            static_cast<const double*>(device_scaled_nibble_),
            static_cast<DeviceShareResult*>(device_result_), count);
        check_cuda_header80(cudaGetLastError(), "header80_pow_kernel launch");
    }
'''
if old_monolithic not in t7:
    raise SystemExit('v1.0.9 monolithic launch marker missing')
t7 = t7.replace(old_monolithic, new_monolithic, 1)
p7.write_text(t7, encoding='utf-8')

main = Path('native/src/app/main_v105.cpp')
main_text = main.read_text(encoding='utf-8')
old_identity = 'PepeW Miner v1.0.9 | Performance & Stability Edition'
if old_identity not in main_text:
    raise SystemExit('v1.0.9 binary identity marker missing')
main_text = main_text.replace(
    old_identity,
    'PepeW Miner v1.1.0 | Performance & Stability Edition', 1)
main.write_text(main_text, encoding='utf-8')

cmake = Path('native/CMakeLists.txt')
ct = cmake.read_text(encoding='utf-8')
if 'project(PepePowMiner VERSION 1.0.9 LANGUAGES C CXX)' not in ct:
    raise SystemExit('prepared v1.0.9 CMake version marker missing')
ct = ct.replace(
    'project(PepePowMiner VERSION 1.0.9 LANGUAGES C CXX)',
    'project(PepePowMiner VERSION 1.1.0 LANGUAGES C CXX)', 1)
old_tuner = '''        add_executable(pepepow_v100_autotune tests/v100_geometry_benchmark.cpp)
        target_link_libraries(pepepow_v100_autotune PRIVATE pepepow_core pepepow_cuda)
        set_target_properties(pepepow_v100_autotune PROPERTIES LINKER_LANGUAGE CUDA CUDA_RESOLVE_DEVICE_SYMBOLS ON)
'''
new_tuner = '''        add_executable(pepepow_v110_autotune tests/v110_cohort_benchmark.cpp)
        target_link_libraries(pepepow_v110_autotune PRIVATE pepepow_core pepepow_cuda)
        set_target_properties(pepepow_v110_autotune PROPERTIES LINKER_LANGUAGE CUDA CUDA_RESOLVE_DEVICE_SYMBOLS ON)
'''
if old_tuner not in ct:
    raise SystemExit('v1.0.9 autotune target marker missing')
ct = ct.replace(old_tuner, new_tuner, 1)
cmake.write_text(ct, encoding='utf-8')

v6 = p6.read_text(encoding='utf-8')
v7 = p7.read_text(encoding='utf-8')
assert 'header80_pow_warp_cohort_kernel' in v6
assert 'v110_hoohash_warp_cohort' in v6
assert '__ballot_sync(kFullWarpMask, lane_active)' in v6
assert 'cohort_threshold' in v6
assert 'grid_stride' in v6
assert 'PEPEPOW_V110_ENGINE' in v7
assert 'PEPEPOW_V110_COHORT_THRESHOLD' in v7
assert 'PEPEPOW_V110_BLOCKS_PER_SM' in v7
assert 'cudaDevAttrMultiProcessorCount' in v7
assert 'PepeW Miner v1.1.0 | Performance & Stability Edition' in main.read_text(encoding='utf-8')
assert 'project(PepePowMiner VERSION 1.1.0 LANGUAGES C CXX)' in cmake.read_text(encoding='utf-8')
assert 'pepepow_v110_autotune' in cmake.read_text(encoding='utf-8')
print('V110_WARP_COHORT_PREPARE=PASS')
