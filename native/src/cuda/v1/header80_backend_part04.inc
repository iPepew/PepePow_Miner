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
            const std::uint32_t high_nibble = static_cast<std::uint32_t>(packed >> 4U);
            const std::uint32_t low_nibble = static_cast<std::uint32_t>(packed & 0x0fU);
            accumulate(matrix, scaled_nibble_table, high_cell, high_nibble,
                       nibble_to_double(high_nibble), hash_mod_fp64, nonce_mod, sum, sw);
            accumulate(matrix, scaled_nibble_table, high_cell + 1, low_nibble,
                       nibble_to_double(low_nibble), hash_mod_fp64, nonce_mod, sum, sw);
        }
    }
    return sum;
}

__device__ __forceinline__ bool hash_words_meet_target(
    const std::uint32_t hash_words[8]) {
    #pragma unroll
    for (int i = 0; i < 8; ++i) {
        const std::uint32_t hash_be = byte_swap32(hash_words[i]);
        const std::uint32_t target_be = kHeader80TargetWords[i];
        if (hash_be < target_be) return true;
        if (hash_be > target_be) return false;
    }
    return true;
}

__device__ __forceinline__ void hoohash_mix_words(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
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
    const double hash_mod_fp64 = u32_to_double_exact(hash_mod);
    const double nonce_mod = u32_to_double_exact(mix_nonce & 0xffU);
    HooHashSwState sw = initial_sw_state();
    #pragma unroll 1
    for (int pair = 0; pair < 32; ++pair) {
        const double even_sum = matrix_row(matrix, scaled_nibble_table, pair * 2, first_pass, hash_mod_fp64, nonce_mod, sw);
        const double odd_sum = matrix_row(matrix, scaled_nibble_table, pair * 2 + 1, first_pass, hash_mod_fp64, nonce_mod, sw);
        const std::uint64_t combined = positive_double_to_u64_rz(even_sum) +
                                       positive_double_to_u64_rz(odd_sum);
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
    const double* __restrict__ scaled_nibble_table,
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
    hoohash_mix_words(matrix, scaled_nibble_table, mix_nonce, first_pass, mixed);
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


#if PEPEPOW_CUDA_HIERARCHICAL_SERVICE704
constexpr unsigned int kHierarchicalGroups = 4U;
constexpr unsigned int kHierarchicalCapacity = 192U;

struct ColdServiceScratch {
    unsigned int task_count[kHierarchicalGroups];
    double task_x[kHierarchicalGroups][kHierarchicalCapacity];
    double task_value[kHierarchicalGroups][kHierarchicalCapacity];
    double task_result[PEPEPOW_CUDA_THREADS];
    unsigned int task_owner[kHierarchicalGroups][kHierarchicalCapacity];
};

__device__ __forceinline__ unsigned int hierarchical_group_for_warp(unsigned int warp) {
    return warp < 6U ? 0U : (warp < 12U ? 1U : (warp < 17U ? 2U : 3U));
}

__device__ __forceinline__ unsigned int hierarchical_first_warp(unsigned int group) {
    return group == 0U ? 0U : (group == 1U ? 6U : (group == 2U ? 12U : 17U));
}

__device__ __forceinline__ unsigned int hierarchical_thread_count(unsigned int group) {
    return group < 2U ? 192U : 160U;
}

__device__ __forceinline__ unsigned int hierarchical_capacity(unsigned int group) {
    return group < 2U ? 192U : 160U;
}

__device__ __forceinline__ void hierarchical_barrier(unsigned int group) {
    const unsigned int count = hierarchical_thread_count(group);
    asm volatile("bar.sync %0, %1;" :: "r"(group + 1U), "r"(count) : "memory");
}
#else
struct ColdServiceScratch {
    unsigned int task_count;
    double task_x[PEPEPOW_CUDA_THREADS];
    double task_value[PEPEPOW_CUDA_THREADS];
    double task_result[PEPEPOW_CUDA_THREADS];
    unsigned int task_owner[PEPEPOW_CUDA_THREADS];
};
#endif

__device__ __forceinline__ void service_accumulate(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    int cell_index, std::uint32_t nibble, double value,
    double hash_mod, double nonce_mod, double& sum, HooHashSwState& sw,
    bool active, ColdServiceScratch& scratch) {
    const bool cold = active && sw_state_is_cold(sw);
    const bool task = cold && nibble != 0U;

