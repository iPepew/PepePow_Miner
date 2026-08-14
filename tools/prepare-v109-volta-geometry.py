from pathlib import Path

# v1.0.9 goes back to the proven exact service24 HooHash path, but removes
# the compile-time 768-thread shared-memory footprint. Runtime block geometry
# now gets a proportional shared scratch allocation, allowing several smaller
# independent blocks to reside on a V100 SM. The HiveOS launcher benchmarks
# safe geometries on the physical GPU and caches the winner.

p4 = Path('native/src/cuda/v1/header80_backend_part04.inc')
t4 = p4.read_text(encoding='utf-8')
old_scratch = '''struct ColdServiceScratch {
    unsigned int task_count;
    double task_x[PEPEPOW_CUDA_THREADS];
    double task_value[PEPEPOW_CUDA_THREADS];
    double task_result[PEPEPOW_CUDA_THREADS];
    unsigned int task_owner[PEPEPOW_CUDA_THREADS];
};
'''
new_scratch = r'''struct ColdServiceScratch {
    unsigned int* task_count;
    double* task_x;
    double* task_value;
    double* task_result;
    unsigned int* task_owner;
};

// Keep the first double-word reserved for the counter so every FP64 array is
// naturally 8-byte aligned. Shared memory then scales with the runtime block
// size instead of always reserving scratch for 768 threads.
constexpr std::size_t cold_service_shared_bytes(unsigned int threads) noexcept {
    return 8U + static_cast<std::size_t>(threads) *
        (3U * sizeof(double) + sizeof(unsigned int));
}

__device__ __forceinline__ ColdServiceScratch make_cold_service_scratch(
    double* raw_words, unsigned int threads) {
    auto* raw = reinterpret_cast<unsigned char*>(raw_words);
    auto* count = reinterpret_cast<unsigned int*>(raw);
    raw += 8U;
    auto* task_x = reinterpret_cast<double*>(raw);
    raw += static_cast<std::size_t>(threads) * sizeof(double);
    auto* task_value = reinterpret_cast<double*>(raw);
    raw += static_cast<std::size_t>(threads) * sizeof(double);
    auto* task_result = reinterpret_cast<double*>(raw);
    raw += static_cast<std::size_t>(threads) * sizeof(double);
    auto* task_owner = reinterpret_cast<unsigned int*>(raw);
    return {count, task_x, task_value, task_result, task_owner};
}
'''
if old_scratch not in t4:
    raise SystemExit('ColdServiceScratch marker missing')
t4 = t4.replace(old_scratch, new_scratch, 1)
p4.write_text(t4, encoding='utf-8')

p5 = Path('native/src/cuda/v1/header80_backend_part05.inc')
t = p5.read_text(encoding='utf-8')
old_producer = '''    double task_x = 0.0;
    if (task) {
        const double cell = matrix[cell_index];
        task_x = cell * hash_mod * value + nonce_mod;
    }
'''
new_producer = '''    // v1.0.9: exact producer-side selector. The expensive service phase only
    // evaluates the selected nonlinear function and does not repeat selector
    // decoding for every service warp.
    double task_y = 0.0;
    unsigned int task_region = 0U;
    if (task) {
        const double cell = matrix[cell_index];
        const double task_x = cell * hash_mod * value + nonce_mod;
        const HooHashSelectorParts selector =
            decode_selector_parts(task_x * kTransformMultiplier * 0.125);
        task_region = selector.one_region;
        const double two = selector.two;
        if (two < 0.25) task_y = task_x + (1.0 + two);
        else if (two < 0.50) task_y = task_x - (1.0 + two);
        else if (two < 0.75) task_y = task_x * (1.0 + two);
        else task_y = task_x / (1.0 + two);
    }
'''
if old_producer not in t:
    raise SystemExit('service producer marker missing')
t = t.replace(old_producer, new_producer, 1)
t = t.replace('scratch.task_x[slot] = task_x;', 'scratch.task_x[slot] = task_y;', 1)
old_owner = '''            scratch.task_owner[slot] =
                static_cast<unsigned int>(threadIdx.x);'''
new_owner = '''            scratch.task_owner[slot] =
                static_cast<unsigned int>(threadIdx.x) |
                (task_region << 16U);'''
if old_owner not in t:
    raise SystemExit('task owner marker missing')
t = t.replace(old_owner, new_owner, 1)

if 'atomicAdd(&scratch.task_count,' not in t:
    raise SystemExit('task_count atomic marker missing')
t = t.replace('atomicAdd(&scratch.task_count,', 'atomicAdd(scratch.task_count,', 1)

start_marker = '    __syncthreads();\n    const unsigned int task_count = scratch.task_count;\n'
a = t.index(start_marker)
b = t.index('\n\n    if (active) {', a)
executor = r'''    __syncthreads();
    const unsigned int task_count = *scratch.task_count;
#if defined(__CUDA_ARCH__) && __CUDA_ARCH__ == 700 && PEPEPOW_CUDA_ASSUME_FINITE
    // Exact service geometry. Runtime block sizes >= 96 always provide at
    // least one warp for each nonlinear region. Multiples of three warps keep
    // the service distribution perfectly balanced; the physical V100
    // autotuner measures the best trade-off between barrier scope and
    // resident-block concurrency.
    const unsigned int warp = static_cast<unsigned int>(threadIdx.x) >> 5U;
    const unsigned int service_lane = static_cast<unsigned int>(threadIdx.x) & 31U;
    const unsigned int total_warps = static_cast<unsigned int>(blockDim.x) >> 5U;
    const unsigned int region = warp % 3U;
    const unsigned int group_index = warp / 3U;
    const unsigned int group_count = (total_warps + 2U - region) / 3U;

    for (unsigned int task_index = group_index * 32U + service_lane;
         task_index < task_count;
         task_index += group_count * 32U) {
        const unsigned int encoded_owner = scratch.task_owner[task_index];
        if ((encoded_owner >> 16U) != region) continue;

        const double y = scratch.task_x[task_index];
        double nonlinear_value;
        if (region == 0U) {
            double sine, cosine;
            sincos(y, &sine, &cosine);
            nonlinear_value = exp(sine + cosine);
        } else if (region == 1U) {
            if (y == kPi / 2.0 || y == 3.0 * kPi / 2.0) {
                nonlinear_value = 0.0;
            } else {
                const double sine = sin(y);
                nonlinear_value = sine * sine;
            }
        } else {
            nonlinear_value = 1.0 / sqrt(fabs(y) + 1.0);
        }

        const unsigned int owner = encoded_owner & 0xffffU;
        scratch.task_result[owner] =
            nonlinear_value * scratch.task_value[task_index] * 1234.0;
    }
    __syncwarp();
    if (threadIdx.x == 0U) *scratch.task_count = 0U;
#else
    if (threadIdx.x < 32U) {
        for (unsigned int task_index = lane;
             task_index < task_count; task_index += 32U) {
            const double nonlinear_value =
                safe_nonlinear(scratch.task_x[task_index]);
            const unsigned int owner = scratch.task_owner[task_index];
            scratch.task_result[owner] =
                nonlinear_value * scratch.task_value[task_index] * 1234.0;
        }
        __syncwarp();
        if (lane == 0U) *scratch.task_count = 0U;
    }
#endif
    __syncthreads();'''
t = t[:a] + executor + t[b:]

old_kernel_scratch = '''#if !defined(__CUDA_ARCH__) || __CUDA_ARCH__ != 700
    __shared__ ColdServiceScratch scratch;
    if (threadIdx.x == 0U) scratch.task_count = 0U;
    __syncthreads();
#endif
'''
new_kernel_scratch = '''    extern __shared__ double cold_service_dynamic[];
    ColdServiceScratch scratch = make_cold_service_scratch(
        cold_service_dynamic, static_cast<unsigned int>(blockDim.x));
    if (threadIdx.x == 0U) *scratch.task_count = 0U;
    __syncthreads();
'''
if old_kernel_scratch not in t:
    raise SystemExit('kernel scratch marker missing')
t = t.replace(old_kernel_scratch, new_kernel_scratch, 1)
p5.write_text(t, encoding='utf-8')

p6 = Path('native/src/cuda/v1/header80_backend_part06.inc')
t6 = p6.read_text(encoding='utf-8')
a = t6.index('#if defined(__CUDA_ARCH__) && __CUDA_ARCH__ == 700\n')
b = t6.index('#endif', a) + len('#endif')
service_call = '''    hoohash_mix_words_service(
        matrix, scaled_nibble_table, byte_swap32(nonce), first_pass,
        mixed, active, scratch);'''
t6 = t6[:a] + service_call + t6[b:]
# service geometry requires all three regions, therefore 96 threads minimum.
t6 = t6.replace(
    'if (threads_per_block_ < 64U ||',
    'if (threads_per_block_ < 96U ||', 1)
t6 = t6.replace(
    '"CUDA threads per block must be a multiple of 32 between 64 and " +',
    '"CUDA threads per block must be a multiple of 32 between 96 and " +', 1)
p6.write_text(t6, encoding='utf-8')

p7 = Path('native/src/cuda/v1/header80_backend_part07.inc')
t7 = p7.read_text(encoding='utf-8')
old_blocks = '''    const unsigned int threads = threads_per_block_;
    const unsigned int blocks = static_cast<unsigned int>((count + threads - 1U) / threads);
'''
new_blocks = '''    const unsigned int threads = threads_per_block_;
    const unsigned int blocks = static_cast<unsigned int>((count + threads - 1U) / threads);
    const std::size_t dynamic_shared_bytes = cold_service_shared_bytes(threads);
'''
if old_blocks not in t7:
    raise SystemExit('launch geometry marker missing')
t7 = t7.replace(old_blocks, new_blocks, 1)
old_cache = '''        check_cuda_header80(
            cudaFuncSetCacheConfig(header80_pow_kernel, cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(header80 monolithic)");
        cache_configured = true;'''
new_cache = '''        check_cuda_header80(
            cudaFuncSetCacheConfig(header80_pow_kernel, cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(header80 monolithic)");
        check_cuda_header80(
            cudaFuncSetAttribute(header80_pow_kernel,
                                 cudaFuncAttributePreferredSharedMemoryCarveout,
                                 cudaSharedmemCarveoutMaxL1),
            "cudaFuncSetAttribute(header80 max L1 carveout)");
        cache_configured = true;'''
if old_cache not in t7:
    raise SystemExit('cache config marker missing')
t7 = t7.replace(old_cache, new_cache, 1)
old_launch = '''    header80_pow_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_),
        static_cast<DeviceShareResult*>(device_result_), count);'''
new_launch = '''    header80_pow_kernel<<<blocks, threads, dynamic_shared_bytes>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_),
        static_cast<DeviceShareResult*>(device_result_), count);'''
if old_launch not in t7:
    raise SystemExit('kernel launch marker missing')
t7 = t7.replace(old_launch, new_launch, 1)
p7.write_text(t7, encoding='utf-8')

main = Path('native/src/app/main_v105.cpp')
main_text = main.read_text(encoding='utf-8')
if 'PepeW Miner v1.0.5' not in main_text:
    raise SystemExit('console version marker missing')
main_text = main_text.replace(
    'PepeW Miner v1.0.5',
    'PepeW Miner v1.0.9 | Performance & Stability Edition')
main.write_text(main_text, encoding='utf-8')

cmake = Path('native/CMakeLists.txt')
ct = cmake.read_text(encoding='utf-8')
if 'project(PepePowMiner VERSION 1.0.6 LANGUAGES C CXX)' not in ct:
    raise SystemExit('CMake base version marker missing')
ct = ct.replace(
    'project(PepePowMiner VERSION 1.0.6 LANGUAGES C CXX)',
    'project(PepePowMiner VERSION 1.0.9 LANGUAGES C CXX)', 1)
for old, new in {
    'tests/test_main.cpp': 'tests/core_tests.cpp',
    'tests/test_cuda.cpp': 'tests/cuda_tests.cpp',
    'tests/test_cuda_header80_validation.cpp': 'tests/cuda_header80_validation.cpp',
}.items():
    if old not in ct:
        raise SystemExit(f'CMake test marker missing: {old}')
    ct = ct.replace(old, new)
old_benchmark = '''        add_executable(pepepow_header80_benchmark tests/benchmark_header80.cpp)\n        target_link_libraries(pepepow_header80_benchmark PRIVATE pepepow_core pepepow_cuda)\n'''
if old_benchmark not in ct:
    raise SystemExit('legacy benchmark CMake marker missing')
new_benchmark = '''        add_executable(pepepow_v100_autotune tests/v100_geometry_benchmark.cpp)\n        target_link_libraries(pepepow_v100_autotune PRIVATE pepepow_core pepepow_cuda)\n        set_target_properties(pepepow_v100_autotune PROPERTIES LINKER_LANGUAGE CUDA CUDA_RESOLVE_DEVICE_SYMBOLS ON)\n'''
ct = ct.replace(old_benchmark, new_benchmark, 1)
if 'target_compile_definitions(pepepowminer PRIVATE PEPEPOW_HAS_CUDA=1)' not in ct:
    raise SystemExit('PEPEPOW_HAS_CUDA final-link safeguard missing')
cmake.write_text(ct, encoding='utf-8')

# Build-time structural gates. Runtime consensus is checked separately by the
# CUDA validation binary and again for every physical autotune candidate.
v4 = p4.read_text(encoding='utf-8')
v5 = p5.read_text(encoding='utf-8')
v6 = p6.read_text(encoding='utf-8')
v7 = p7.read_text(encoding='utf-8')
assert 'cold_service_shared_bytes' in v4
assert 'make_cold_service_scratch' in v4
assert 'atomicAdd(scratch.task_count' in v5
assert '(task_region << 16U)' in v5
assert 'exp(sine + cosine)' in v5
assert '1.0 / sqrt(fabs(y) + 1.0)' in v5
assert 'extern __shared__ double cold_service_dynamic[]' in v5
assert 'hoohash_mix_words_service' in v6
assert 'threads_per_block_ < 96U' in v6
assert 'dynamic_shared_bytes' in v7
assert 'cudaSharedmemCarveoutMaxL1' in v7
assert 'PepeW Miner v1.0.9 | Performance & Stability Edition' in main.read_text(encoding='utf-8')
assert 'project(PepePowMiner VERSION 1.0.9 LANGUAGES C CXX)' in cmake.read_text(encoding='utf-8')
assert 'pepepow_v100_autotune' in cmake.read_text(encoding='utf-8')
print('V109_VOLTA_GEOMETRY_PREPARE=PASS')
