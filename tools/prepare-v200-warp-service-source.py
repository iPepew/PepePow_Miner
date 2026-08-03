from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: prepare-v200-warp-service-source.py SOURCE MODE")

path = Path(sys.argv[1])
mode = sys.argv[2]
text = path.read_text(encoding="utf-8")

if mode not in {"service", "service-zero"}:
    raise SystemExit(f"ERROR: unknown mode: {mode}")
zero_fast = mode == "service-zero"

signature = '''__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void header80_pow_kernel('''
start = text.find(signature)
if start < 0:
    raise SystemExit("ERROR: header80_pow_kernel signature not found")
brace = text.find("{", start)
if brace < 0:
    raise SystemExit("ERROR: kernel opening brace not found")
depth = 0
end = None
for i in range(brace, len(text)):
    ch = text[i]
    if ch == "{":
        depth += 1
    elif ch == "}":
        depth -= 1
        if depth == 0:
            end = i + 1
            break
if end is None:
    raise SystemExit("ERROR: kernel closing brace not found")

service = r'''
struct ColdServiceScratch {
    unsigned int task_count;
    double task_x[PEPEPOW_CUDA_THREADS];
    double task_value[PEPEPOW_CUDA_THREADS];
    double task_result[PEPEPOW_CUDA_THREADS];
    unsigned int task_owner[PEPEPOW_CUDA_THREADS];
};

__device__ __forceinline__ void service_accumulate(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    int cell_index, std::uint32_t nibble, double value,
    double hash_mod, double nonce_mod, double& sum, HooHashSwState& sw,
    bool active, ColdServiceScratch& scratch) {
    const bool cold = active && sw_state_is_cold(sw);
    const bool task = cold && nibble != 0U;

    double warm_contribution = 0.0;
    if (active) {
#if PEPEPOW_CUDA_SCALED_NIBBLE_TABLE
        warm_contribution = __ldg(
            scaled_nibble_table +
            static_cast<std::size_t>(cell_index) * 16U + nibble);
#elif PEPEPOW_CUDA_SCALED_MATRIX
        warm_contribution = kHeader80ScaledMatrix[cell_index] * value;
#else
        warm_contribution = matrix[cell_index] * 0.0001 * value;
#endif
    }

    double task_x = 0.0;
    if (task) {
        const double cell = matrix[cell_index];
        task_x = cell * hash_mod * value + nonce_mod;
    }

    const unsigned int lane = static_cast<unsigned int>(threadIdx.x) & 31U;
    const unsigned int warp_mask = __activemask();
    const unsigned int task_mask = __ballot_sync(warp_mask, task);
    unsigned int slot = 0U;
    if (task_mask != 0U) {
        const int leader = __ffs(static_cast<int>(task_mask)) - 1;
        unsigned int base = 0U;
        if (static_cast<int>(lane) == leader) {
            base = atomicAdd(&scratch.task_count,
                             static_cast<unsigned int>(__popc(task_mask)));
        }
        base = __shfl_sync(warp_mask, base, leader);
        const unsigned int lower_mask =
            lane == 0U ? 0U : ((1U << lane) - 1U);
        slot = base + static_cast<unsigned int>(
            __popc(task_mask & lower_mask));
        if (task) {
            scratch.task_x[slot] = task_x;
            scratch.task_value[slot] = value;
            scratch.task_owner[slot] =
                static_cast<unsigned int>(threadIdx.x);
        }
    }

    __syncthreads();
    const unsigned int task_count = scratch.task_count;
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
    __syncthreads();

    if (active) {
        if (cold) {
            if (nibble != 0U) {
                sum += scratch.task_result[threadIdx.x];
            }
        } else {
            sum += warm_contribution;
        }
        update_sw_state(sw, sum);
    }
}

__device__ __forceinline__ double matrix_row_service(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    int row, const std::uint32_t first_pass[8], double hash_mod_fp64,
    double nonce_mod, HooHashSwState& sw, bool active,
    ColdServiceScratch& scratch) {
    double sum = 0.0;
    const int row_offset = row * 64;
    #pragma unroll 1
    for (int word_index = 0; word_index < 8; ++word_index) {
        const std::uint32_t packed_word = first_pass[word_index];
        #pragma unroll
        for (int byte_in_word = 0; byte_in_word < 4; ++byte_in_word) {
            const int byte_index = word_index * 4 + byte_in_word;
            const std::uint8_t packed = static_cast<std::uint8_t>(
                packed_word >>
                static_cast<unsigned int>(byte_in_word * 8));
            const int high_cell = row_offset + byte_index * 2;
            const std::uint32_t high_nibble =
                static_cast<std::uint32_t>(packed >> 4U);
            const std::uint32_t low_nibble =
                static_cast<std::uint32_t>(packed & 0x0fU);
            service_accumulate(
                matrix, scaled_nibble_table, high_cell, high_nibble,
                nibble_to_double(high_nibble), hash_mod_fp64, nonce_mod,
                sum, sw, active, scratch);
            service_accumulate(
                matrix, scaled_nibble_table, high_cell + 1, low_nibble,
                nibble_to_double(low_nibble), hash_mod_fp64, nonce_mod,
                sum, sw, active, scratch);
        }
    }
    return sum;
}

__device__ __forceinline__ void hoohash_mix_words_service(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    std::uint32_t mix_nonce, const std::uint32_t first_pass[8],
    std::uint32_t mixed[8], bool active, ColdServiceScratch& scratch) {
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
    #pragma unroll 1
    for (int pair = 0; pair < 32; ++pair) {
        const double even_sum = matrix_row_service(
            matrix, scaled_nibble_table, pair * 2, first_pass,
            hash_mod_fp64, nonce_mod, sw, active, scratch);
        const double odd_sum = matrix_row_service(
            matrix, scaled_nibble_table, pair * 2 + 1, first_pass,
            hash_mod_fp64, nonce_mod, sw, active, scratch);
        if (active) {
            const std::uint64_t combined =
                positive_double_to_u64_rz(even_sum) +
                positive_double_to_u64_rz(odd_sum);
            const std::uint32_t shift =
                static_cast<std::uint32_t>((pair & 3) * 8);
            mixed[pair >> 2] ^=
                static_cast<std::uint32_t>(combined & 0xffU) << shift;
        }
    }
}

__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void header80_pow_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    DeviceShareResult* __restrict__ result,
    std::size_t count) {
    __shared__ ColdServiceScratch scratch;
    if (threadIdx.x == 0U) scratch.task_count = 0U;
    __syncthreads();

    const std::size_t index =
        static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    const bool active = index < count;
    const std::uint32_t nonce =
        first_nonce + static_cast<std::uint32_t>(active ? index : 0U);

    std::uint32_t first_pass[8]{};
    std::uint32_t mixed[8]{};
    std::uint32_t final_hash[8]{};
    if (active) blake3_header80_words(nonce, first_pass);

    hoohash_mix_words_service(
        matrix, scaled_nibble_table, byte_swap32(nonce), first_pass,
        mixed, active, scratch);

    if (!active) return;
    blake3_32_words(mixed, final_hash);
    if (!hash_words_meet_target(final_hash)) return;
    if (atomicCAS(&result->found, 0U, 1U) == 0U) {
        result->nonce = nonce;
        #pragma unroll
        for (int i = 0; i < 8; ++i) {
            result->hash_words[i] = final_hash[i];
        }
    }
}
'''


if zero_fast:
    service = service.replace(
        "        update_sw_state(sw, sum);\n",
        "        if (!(cold && nibble == 0U)) update_sw_state(sw, sum);\n",
        1,
    )

text = text[:start] + service + text[end:]
path.write_text(text, encoding="utf-8")
