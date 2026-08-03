from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: prepare-v080-grand-source.py SOURCE MODE")

path = Path(sys.argv[1])
mode = sys.argv[2]
text = path.read_text(encoding="utf-8")

selector_old = r'''__device__ __forceinline__ double nonlinear(double x) {
    const double scaled = x * kTransformMultiplier;
    const double one_base = scaled / 8.0;
    const double one = positive_fraction(one_base);
#if PEPEPOW_CUDA_DERIVE_TWO
    const double doubled_one = one + one;
    const double two = doubled_one >= 1.0 ? doubled_one - 1.0 : doubled_one;
#else
    const double two = positive_fraction(scaled / 4.0);
#endif
    double y;
    if (two < 0.25) y = x + (1.0 + two);
    else if (two < 0.50) y = x - (1.0 + two);
    else if (two < 0.75) y = x * (1.0 + two);
    else y = x / (1.0 + two);
    if (one < 0.33) {
        double sine, cosine;
        sincos(y, &sine, &cosine);
        return exp(sine + cosine);
    }
    if (one < 0.66) {
        if (y == kPi / 2.0 || y == 3.0 * kPi / 2.0) return 0.0;
        const double sine = sin(y);
        return sine * sine;
    }
    return 1.0 / sqrt(fabs(y) + 1.0);
}'''

selector_new = r'''__device__ __forceinline__ unsigned int fraction_region_033_066(double value) {
    // Consensus inputs are positive and finite. Compare the fractional
    // remainder directly with the exact binary64 encodings of 0.33 and 0.66.
    // This removes one full fraction-normalization path without changing the
    // branch selected by the reference implementation.
    const std::uint64_t bits =
        static_cast<std::uint64_t>(__double_as_longlong(value));
    const unsigned int exponent =
        static_cast<unsigned int>((bits >> 52U) & 0x7ffULL);
    constexpr std::uint64_t kBits033 = 0x3fd51eb851eb851fULL;
    constexpr std::uint64_t kBits066 = 0x3fe51eb851eb851fULL;
    constexpr std::uint64_t kSig033 = 0x00151eb851eb851fULL;
    constexpr std::uint64_t kSig066 = 0x00151eb851eb851fULL;

    if (exponent < 1023U) {
        if (bits < kBits033) return 0U;
        if (bits < kBits066) return 1U;
        return 2U;
    }
    const unsigned int integer_bits = exponent - 1023U;
    if (integer_bits >= 52U) return 0U;
    const unsigned int fractional_width = 52U - integer_bits;
    const std::uint64_t remainder =
        bits & ((std::uint64_t{1} << fractional_width) - 1ULL);
    if (remainder == 0ULL) return 0U;
    if ((remainder << (54U - fractional_width)) < kSig033) return 0U;
    if ((remainder << (53U - fractional_width)) < kSig066) return 1U;
    return 2U;
}

__device__ __forceinline__ double nonlinear(double x) {
    const double scaled = x * kTransformMultiplier;
    const unsigned int one_region =
        fraction_region_033_066(scaled * 0.125);
    const double two = positive_fraction(scaled * 0.25);
    double y;
    if (two < 0.25) y = x + (1.0 + two);
    else if (two < 0.50) y = x - (1.0 + two);
    else if (two < 0.75) y = x * (1.0 + two);
    else y = x / (1.0 + two);
    if (one_region == 0U) {
        double sine, cosine;
        sincos(y, &sine, &cosine);
        return exp(sine + cosine);
    }
    if (one_region == 1U) {
        if (y == kPi / 2.0 || y == 3.0 * kPi / 2.0) return 0.0;
        const double sine = sin(y);
        return sine * sine;
    }
    return 1.0 / sqrt(fabs(y) + 1.0);
}'''

if "selector" in mode:
    count = text.count(selector_old)
    if count != 1:
        raise SystemExit(f"ERROR: nonlinear block count={count}")
    text = text.replace(selector_old, selector_new, 1)

if "dual" in mode:
    first_kernel_marker = r'''__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void header80_first_kernel('''

    dual_helpers = r'''__device__ __forceinline__ void matrix_row_two(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    int row,
    const std::uint32_t first_pass0[8], double hash_mod0,
    double nonce_mod0, HooHashSwState& sw0, double& sum0,
    const std::uint32_t first_pass1[8], double hash_mod1,
    double nonce_mod1, HooHashSwState& sw1, double& sum1) {
    sum0 = 0.0;
    sum1 = 0.0;
    const int row_offset = row * 64;
    #pragma unroll 1
    for (int word_index = 0; word_index < 8; ++word_index) {
        const std::uint32_t packed_word0 = first_pass0[word_index];
        const std::uint32_t packed_word1 = first_pass1[word_index];
        #pragma unroll
        for (int byte_in_word = 0; byte_in_word < 4; ++byte_in_word) {
            const int byte_index = word_index * 4 + byte_in_word;
            const unsigned int shift =
                static_cast<unsigned int>(byte_in_word * 8);
            const std::uint32_t packed0 = (packed_word0 >> shift) & 0xffU;
            const std::uint32_t packed1 = (packed_word1 >> shift) & 0xffU;
            const int high_cell = row_offset + byte_index * 2;
            const std::uint32_t high0 = packed0 >> 4U;
            const std::uint32_t low0 = packed0 & 0x0fU;
            const std::uint32_t high1 = packed1 >> 4U;
            const std::uint32_t low1 = packed1 & 0x0fU;
            accumulate(matrix, scaled_nibble_table, high_cell, high0,
                       nibble_to_double(high0), hash_mod0, nonce_mod0,
                       sum0, sw0);
            accumulate(matrix, scaled_nibble_table, high_cell, high1,
                       nibble_to_double(high1), hash_mod1, nonce_mod1,
                       sum1, sw1);
            accumulate(matrix, scaled_nibble_table, high_cell + 1, low0,
                       nibble_to_double(low0), hash_mod0, nonce_mod0,
                       sum0, sw0);
            accumulate(matrix, scaled_nibble_table, high_cell + 1, low1,
                       nibble_to_double(low1), hash_mod1, nonce_mod1,
                       sum1, sw1);
        }
    }
}

__device__ __forceinline__ void hoohash_mix_words_two(
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    std::uint32_t mix_nonce0, const std::uint32_t first_pass0[8],
    std::uint32_t mixed0[8],
    std::uint32_t mix_nonce1, const std::uint32_t first_pass1[8],
    std::uint32_t mixed1[8]) {
    std::uint32_t hash_xor0 = 0U;
    std::uint32_t hash_xor1 = 0U;
    #pragma unroll
    for (int i = 0; i < 8; ++i) {
        hash_xor0 ^= first_pass0[i];
        hash_xor1 ^= first_pass1[i];
        mixed0[i] = first_pass0[i];
        mixed1[i] = first_pass1[i];
    }
    const double hash_mod0 =
        u32_to_double_exact(byte_swap32(hash_xor0));
    const double hash_mod1 =
        u32_to_double_exact(byte_swap32(hash_xor1));
    const double nonce_mod0 = u32_to_double_exact(mix_nonce0 & 0xffU);
    const double nonce_mod1 = u32_to_double_exact(mix_nonce1 & 0xffU);
    HooHashSwState sw0 = initial_sw_state();
    HooHashSwState sw1 = initial_sw_state();
    #pragma unroll 1
    for (int pair = 0; pair < 32; ++pair) {
        double even0, even1, odd0, odd1;
        matrix_row_two(matrix, scaled_nibble_table, pair * 2,
                       first_pass0, hash_mod0, nonce_mod0, sw0, even0,
                       first_pass1, hash_mod1, nonce_mod1, sw1, even1);
        matrix_row_two(matrix, scaled_nibble_table, pair * 2 + 1,
                       first_pass0, hash_mod0, nonce_mod0, sw0, odd0,
                       first_pass1, hash_mod1, nonce_mod1, sw1, odd1);
        const std::uint64_t combined0 =
            positive_double_to_u64_rz(even0) +
            positive_double_to_u64_rz(odd0);
        const std::uint64_t combined1 =
            positive_double_to_u64_rz(even1) +
            positive_double_to_u64_rz(odd1);
        const std::uint32_t shift =
            static_cast<std::uint32_t>((pair & 3) * 8);
        mixed0[pair >> 2] ^=
            static_cast<std::uint32_t>(combined0 & 0xffU) << shift;
        mixed1[pair >> 2] ^=
            static_cast<std::uint32_t>(combined1 & 0xffU) << shift;
    }
}

'''

    count = text.count(first_kernel_marker)
    if count != 1:
        raise SystemExit(f"ERROR: first-kernel marker count={count}")
    text = text.replace(first_kernel_marker,
                        dual_helpers + first_kernel_marker, 1)

    namespace_marker = "} // namespace\n\nHeader80CudaBackend::Header80CudaBackend"
    sequential = "seq" in mode

    if sequential:
        dual_kernel = r'''__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void header80_pow2_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    DeviceShareResult* __restrict__ result,
    std::size_t count) {
    const std::size_t first_index =
        (static_cast<std::size_t>(blockIdx.x) * blockDim.x +
         threadIdx.x) * 2U;
    if (first_index >= count) return;
    #pragma unroll 1
    for (int slot = 0; slot < 2; ++slot) {
        const std::size_t index =
            first_index + static_cast<std::size_t>(slot);
        if (index >= count) break;
        const std::uint32_t nonce =
            first_nonce + static_cast<std::uint32_t>(index);
        std::uint32_t first_pass[8];
        std::uint32_t mixed[8];
        std::uint32_t final_hash[8];
        blake3_header80_words(nonce, first_pass);
        hoohash_mix_words(matrix, scaled_nibble_table,
                          byte_swap32(nonce), first_pass, mixed);
        blake3_32_words(mixed, final_hash);
        if (hash_words_meet_target(final_hash) &&
            atomicCAS(&result->found, 0U, 1U) == 0U) {
            result->nonce = nonce;
            #pragma unroll
            for (int i = 0; i < 8; ++i) {
                result->hash_words[i] = final_hash[i];
            }
        }
    }
}

'''
    else:
        dual_kernel = r'''__global__ __launch_bounds__(PEPEPOW_CUDA_THREADS, PEPEPOW_CUDA_MIN_BLOCKS)
void header80_pow2_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    const double* __restrict__ scaled_nibble_table,
    DeviceShareResult* __restrict__ result,
    std::size_t count) {
    const std::size_t first_index =
        (static_cast<std::size_t>(blockIdx.x) * blockDim.x +
         threadIdx.x) * 2U;
    if (first_index >= count) return;
    const std::uint32_t nonce0 =
        first_nonce + static_cast<std::uint32_t>(first_index);
    if (first_index + 1U >= count) {
        std::uint32_t first_pass[8];
        std::uint32_t mixed[8];
        std::uint32_t final_hash[8];
        blake3_header80_words(nonce0, first_pass);
        hoohash_mix_words(matrix, scaled_nibble_table,
                          byte_swap32(nonce0), first_pass, mixed);
        blake3_32_words(mixed, final_hash);
        if (hash_words_meet_target(final_hash) &&
            atomicCAS(&result->found, 0U, 1U) == 0U) {
            result->nonce = nonce0;
            #pragma unroll
            for (int i = 0; i < 8; ++i) {
                result->hash_words[i] = final_hash[i];
            }
        }
        return;
    }

    const std::uint32_t nonce1 = nonce0 + 1U;
    std::uint32_t first0[8], first1[8];
    std::uint32_t mixed0[8], mixed1[8];
    std::uint32_t final0[8], final1[8];
    blake3_header80_words(nonce0, first0);
    blake3_header80_words(nonce1, first1);
    hoohash_mix_words_two(matrix, scaled_nibble_table,
                          byte_swap32(nonce0), first0, mixed0,
                          byte_swap32(nonce1), first1, mixed1);
    blake3_32_words(mixed0, final0);
    blake3_32_words(mixed1, final1);

    if (hash_words_meet_target(final0) &&
        atomicCAS(&result->found, 0U, 1U) == 0U) {
        result->nonce = nonce0;
        #pragma unroll
        for (int i = 0; i < 8; ++i) result->hash_words[i] = final0[i];
    }
    if (hash_words_meet_target(final1) &&
        atomicCAS(&result->found, 0U, 1U) == 0U) {
        result->nonce = nonce1;
        #pragma unroll
        for (int i = 0; i < 8; ++i) result->hash_words[i] = final1[i];
    }
}

'''

    count = text.count(namespace_marker)
    if count != 1:
        raise SystemExit(f"ERROR: namespace marker count={count}")
    text = text.replace(namespace_marker,
                        dual_kernel + namespace_marker, 1)

    blocks_old = r'''    constexpr unsigned int threads = static_cast<unsigned int>(PEPEPOW_CUDA_THREADS);
    const unsigned int blocks = static_cast<unsigned int>((count + threads - 1U) / threads);'''
    blocks_new = r'''    constexpr unsigned int threads = static_cast<unsigned int>(PEPEPOW_CUDA_THREADS);
    const unsigned int blocks = static_cast<unsigned int>(
        (count + static_cast<std::size_t>(threads) * 2U - 1U) /
        (static_cast<std::size_t>(threads) * 2U));'''
    count = text.count(blocks_old)
    if count != 1:
        raise SystemExit(f"ERROR: launch-block calculation count={count}")
    text = text.replace(blocks_old, blocks_new, 1)

    launch_old = r'''    static thread_local bool cache_configured = false;
    if (!cache_configured) {
        check_cuda_header80(
            cudaFuncSetCacheConfig(header80_pow_kernel, cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(header80 monolithic)");
        cache_configured = true;
    }
    header80_pow_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_),
        static_cast<DeviceShareResult*>(device_result_), count);
    check_cuda_header80(cudaGetLastError(), "header80_pow_kernel launch");'''
    launch_new = r'''    static thread_local bool cache_configured = false;
    if (!cache_configured) {
        check_cuda_header80(
            cudaFuncSetCacheConfig(header80_pow2_kernel, cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(header80 dual-nonce)");
        cache_configured = true;
    }
    header80_pow2_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_),
        static_cast<DeviceShareResult*>(device_result_), count);
    check_cuda_header80(cudaGetLastError(), "header80_pow2_kernel launch");'''
    count = text.count(launch_old)
    if count != 1:
        raise SystemExit(f"ERROR: monolithic launch block count={count}")
    text = text.replace(launch_old, launch_new, 1)

path.write_text(text, encoding="utf-8")
