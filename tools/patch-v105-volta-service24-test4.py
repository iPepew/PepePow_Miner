from pathlib import Path

p5 = Path('native/src/cuda/v1/header80_backend_part05.inc')
t = p5.read_text(encoding='utf-8')

old = '''    double task_x = 0.0;
    if (task) {
        const double cell = matrix[cell_index];
        task_x = cell * hash_mod * value + nonce_mod;
    }
'''
new = '''    // test4: compute the exact selector and transformed y once in the
    // producer thread. The service phase then spends its time only on the
    // expensive transcendental function for the selected region.
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
    raise SystemExit('producer marker missing')
t = t.replace(old, new, 1)
t = t.replace('scratch.task_x[slot] = task_x;', 'scratch.task_x[slot] = task_y;', 1)

old_owner = '''            scratch.task_owner[slot] =
                static_cast<unsigned int>(threadIdx.x);'''
new_owner = '''            scratch.task_owner[slot] =
                static_cast<unsigned int>(threadIdx.x) |
                (task_region << 16U);'''
if old_owner not in t:
    raise SystemExit('owner marker missing')
t = t.replace(old_owner, new_owner, 1)

start_marker = '    __syncthreads();\n    const unsigned int task_count = scratch.task_count;\n'
a = t.index(start_marker)
b = t.index('\n\n    if (active) {', a)
executor = r'''    __syncthreads();
    const unsigned int task_count = scratch.task_count;
#if defined(__CUDA_ARCH__) && __CUDA_ARCH__ == 700 && PEPEPOW_CUDA_ASSUME_FINITE
    // test4: all warps in the block participate in nonlinear service.
    // With 768 threads there are 24 warps, divided as 8 warps per region.
    const unsigned int warp = static_cast<unsigned int>(threadIdx.x) >> 5U;
    const unsigned int service_lane = static_cast<unsigned int>(threadIdx.x) & 31U;
    const unsigned int total_warps = static_cast<unsigned int>(blockDim.x) >> 5U;
    const unsigned int region = warp % 3U;
    const unsigned int group_index = warp / 3U;
    const unsigned int group_count = (total_warps + 2U - region) / 3U;

    // Each region group scans the complete compact task list, but its warps
    // split that scan among themselves. A task is executed only by the group
    // matching the selector region stored by the producer.
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

v5 = p5.read_text(encoding='utf-8')
v6 = p6.read_text(encoding='utf-8')
assert '(task_region << 16U)' in v5
assert 'group_count' in v5
assert 'all warps in the block participate' in v5
assert '__shared__ ColdServiceScratch scratch' in v5
assert 'hoohash_mix_words_service' in v6
print('VOLTA_SERVICE24_PATCH=PASS')
