from pathlib import Path

# v1.0.8 returns to the proven v1.0.5-test4 service24 topology and applies
# conservative fast nonlinear primitives that retain near-FP64 accuracy.
# Exact CPU candidate validation remains mandatory in the miner.

p4 = Path('native/src/cuda/v1/header80_backend_part04.inc')
t4 = p4.read_text(encoding='utf-8')

scratch_marker = '''struct ColdServiceScratch {
    unsigned int task_count;
    double task_x[PEPEPOW_CUDA_THREADS];
    double task_value[PEPEPOW_CUDA_THREADS];
    double task_result[PEPEPOW_CUDA_THREADS];
    unsigned int task_owner[PEPEPOW_CUDA_THREADS];
};
'''
if scratch_marker not in t4:
    raise SystemExit('ColdServiceScratch marker missing')

fast_helpers = r'''

// v1.0.8 volta-fast1 primitives.
// exp input is sin(y)+cos(y), therefore x is bounded by +/-sqrt(2).
// Range reduction keeps r in approximately +/-ln(2)/2 and a degree-12
// Taylor polynomial stays around double-rounding accuracy over this interval.
__device__ __forceinline__ double volta_fast1_exp_small(double x) {
    constexpr double kInvLn2 = 1.44269504088896340735992468100189214;
    constexpr double kLn2 = 0.693147180559945309417232121458176568;
    const int k = __double2int_rn(x * kInvLn2);
    const double r = x - static_cast<double>(k) * kLn2;

    double p = 1.0 / 479001600.0; // 1/12!
    p = 1.0 / 39916800.0 + r * p;
    p = 1.0 / 3628800.0 + r * p;
    p = 1.0 / 362880.0 + r * p;
    p = 1.0 / 40320.0 + r * p;
    p = 1.0 / 5040.0 + r * p;
    p = 1.0 / 720.0 + r * p;
    p = 1.0 / 120.0 + r * p;
    p = 1.0 / 24.0 + r * p;
    p = 1.0 / 6.0 + r * p;
    p = 0.5 + r * p;
    p = 1.0 + r * p;
    p = 1.0 + r * p;

    if (k == 2) return p * 4.0;
    if (k == 1) return p * 2.0;
    if (k == -1) return p * 0.5;
    if (k == -2) return p * 0.25;
    return p;
}

// HooHash V110 bounds z=fabs(y)+1 below the normal FP32 overflow range.
// rsqrtf supplies a cheap seed; two Newton steps in FP64 restore roughly
// double precision without issuing a full FP64 sqrt instruction.
__device__ __forceinline__ double volta_fast1_rsqrt(double z) {
    double r = static_cast<double>(rsqrtf(static_cast<float>(z)));
    r = r * (1.5 - 0.5 * z * r * r);
    r = r * (1.5 - 0.5 * z * r * r);
    return r;
}
'''
t4 = t4.replace(scratch_marker, scratch_marker + fast_helpers, 1)
p4.write_text(t4, encoding='utf-8')

p5 = Path('native/src/cuda/v1/header80_backend_part05.inc')
t = p5.read_text(encoding='utf-8')

old = '''    double task_x = 0.0;
    if (task) {
        const double cell = matrix[cell_index];
        task_x = cell * hash_mod * value + nonce_mod;
    }
'''
new = '''    // service24/fast1: producer computes the exact selector and transformed
    // y once. Service warps only execute the selected nonlinear primitive.
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
if old not in t:
    raise SystemExit('service24 producer marker missing')
t = t.replace(old, new, 1)
t = t.replace('scratch.task_x[slot] = task_x;', 'scratch.task_x[slot] = task_y;', 1)

old_owner = '''            scratch.task_owner[slot] =
                static_cast<unsigned int>(threadIdx.x);'''
new_owner = '''            scratch.task_owner[slot] =
                static_cast<unsigned int>(threadIdx.x) |
                (task_region << 16U);'''
if old_owner not in t:
    raise SystemExit('service24 owner marker missing')
t = t.replace(old_owner, new_owner, 1)

start_marker = '    __syncthreads();\n    const unsigned int task_count = scratch.task_count;\n'
a = t.index(start_marker)
b = t.index('\n\n    if (active) {', a)
executor = r'''    __syncthreads();
    const unsigned int task_count = scratch.task_count;
#if defined(__CUDA_ARCH__) && __CUDA_ARCH__ == 700 && PEPEPOW_CUDA_ASSUME_FINITE
    // v1.0.8 service24: 24 warps split into 3 nonlinear regions.
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
            nonlinear_value = volta_fast1_exp_small(sine + cosine);
        } else if (region == 1U) {
            if (y == kPi / 2.0 || y == 3.0 * kPi / 2.0) {
                nonlinear_value = 0.0;
            } else {
                const double sine = sin(y);
                nonlinear_value = sine * sine;
            }
        } else {
            nonlinear_value = volta_fast1_rsqrt(fabs(y) + 1.0);
        }

        const unsigned int owner = encoded_owner & 0xffffU;
        scratch.task_result[owner] =
            nonlinear_value * scratch.task_value[task_index] * 1234.0;
    }
    __syncwarp();
    if (threadIdx.x == 0U) scratch.task_count = 0U;
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
        if (lane == 0U) scratch.task_count = 0U;
    }
#endif
    __syncthreads();'''
t = t[:a] + executor + t[b:]

scratch_start = '#if !defined(__CUDA_ARCH__) || __CUDA_ARCH__ != 700\n'
scratch_end = '#endif\n\n    const std::size_t index'
a = t.index(scratch_start)
b = t.index(scratch_end, a)
replacement = (
    '    __shared__ ColdServiceScratch scratch;\n'
    '    if (threadIdx.x == 0U) scratch.task_count = 0U;\n'
    '    __syncthreads();\n\n'
    '    const std::size_t index'
)
t = t[:a] + replacement + t[b + len(scratch_end):]
p5.write_text(t, encoding='utf-8')

p6 = Path('native/src/cuda/v1/header80_backend_part06.inc')
t = p6.read_text(encoding='utf-8')
a = t.index('#if defined(__CUDA_ARCH__) && __CUDA_ARCH__ == 700\n')
b = t.index('#endif', a) + len('#endif')
replacement = '''    hoohash_mix_words_service(
        matrix, scaled_nibble_table, byte_swap32(nonce), first_pass,
        mixed, active, scratch);'''
p6.write_text(t[:a] + replacement + t[b:], encoding='utf-8')

main = Path('native/src/app/main_v105.cpp')
text = main.read_text(encoding='utf-8')
if 'PepeW Miner v1.0.5' not in text:
    raise SystemExit('console version marker missing')
text = text.replace('PepeW Miner v1.0.5', 'PepeW Miner v1.0.8')
main.write_text(text, encoding='utf-8')

cmake = Path('native/CMakeLists.txt')
text = cmake.read_text(encoding='utf-8')
if 'project(PepePowMiner VERSION 1.0.6 LANGUAGES C CXX)' not in text:
    raise SystemExit('CMake base version marker missing')
text = text.replace(
    'project(PepePowMiner VERSION 1.0.6 LANGUAGES C CXX)',
    'project(PepePowMiner VERSION 1.0.8 LANGUAGES C CXX)', 1)
replacements = {
    'tests/test_main.cpp': 'tests/core_tests.cpp',
    'tests/test_cuda.cpp': 'tests/cuda_tests.cpp',
    'tests/test_cuda_header80_validation.cpp': 'tests/cuda_header80_validation.cpp',
}
for old, new in replacements.items():
    if old not in text:
        raise SystemExit(f'CMake test marker not found: {old}')
    text = text.replace(old, new)
benchmark = '''        add_executable(pepepow_header80_benchmark tests/benchmark_header80.cpp)\n        target_link_libraries(pepepow_header80_benchmark PRIVATE pepepow_core pepepow_cuda)\n'''
if benchmark in text:
    text = text.replace(benchmark, '')
if 'target_compile_definitions(pepepowminer PRIVATE PEPEPOW_HAS_CUDA=1)' not in text:
    raise SystemExit('PEPEPOW_HAS_CUDA final-link safeguard missing')
cmake.write_text(text, encoding='utf-8')

v4 = p4.read_text(encoding='utf-8')
v5 = p5.read_text(encoding='utf-8')
v6 = p6.read_text(encoding='utf-8')
assert 'volta_fast1_exp_small' in v4
assert 'volta_fast1_rsqrt' in v4
assert '(task_region << 16U)' in v5
assert 'volta_fast1_exp_small(sine + cosine)' in v5
assert 'volta_fast1_rsqrt(fabs(y) + 1.0)' in v5
assert 'group_count' in v5
assert '__shared__ ColdServiceScratch scratch' in v5
assert 'hoohash_mix_words_service' in v6
assert 'PepeW Miner v1.0.8' in main.read_text(encoding='utf-8')
assert 'project(PepePowMiner VERSION 1.0.8 LANGUAGES C CXX)' in cmake.read_text(encoding='utf-8')
print('V108_VOLTA_FAST1_PREPARE=PASS')
