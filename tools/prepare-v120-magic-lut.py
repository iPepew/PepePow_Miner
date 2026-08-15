from pathlib import Path
import runpy

# v1.2.0 starts from the proven exact v1.0.9 service engine and adds a
# fundamentally different speculative V100 solver. The magic engine keeps the
# exact selector, SW state and FP64 accumulators, but removes the large-argument
# sin/cos/exp hot path. Phase is extracted directly from a fixed-point 2/pi
# product and two periodic nonlinear functions are evaluated from a 65,536-node
# cubic-Hermite table resident in GPU global/L2 memory.
#
# The exact service768 kernel remains in the same binary as a fail-safe. The
# physical autotuner scores magic by effective_hps = raw_hps * exact_hash_rate,
# and every pool candidate is still CPU validated before submission.

runpy.run_path('tools/prepare-v109-volta-geometry.py', run_name='__main__')

p0 = Path('native/src/cuda/v1/header80_backend_part00.inc')
t0 = p0.read_text(encoding='utf-8')
if '#include <cstdlib>\n' not in t0:
    t0 = t0.replace('#include <cstdint>\n', '#include <cstdint>\n#include <cstdlib>\n', 1)

symbol_marker = '''__device__ __constant__ std::uint8_t kHeader80Schedule[7][16] = {
'''
pos = t0.index(symbol_marker)
# Insert the large LUT symbols immediately before the existing schedule. They
# are __device__ global memory (not __constant__) because the two double2 tables
# total 2 MiB, while Volta constant memory is only 64 KiB.
magic_symbols = r'''constexpr unsigned int kV120MagicLutBits = 16U;
constexpr unsigned int kV120MagicLutSize = 1U << kV120MagicLutBits;
constexpr unsigned int kV120MagicLutMask = kV120MagicLutSize - 1U;
constexpr double kV120TwoPi = 6.2831853071795864769252867665590057683943387987502;
constexpr double kV120MagicStep = kV120TwoPi / static_cast<double>(kV120MagicLutSize);

// x = function value, y = derivative with respect to theta. Cubic Hermite
// interpolation then needs only two adjacent double2 loads per cold trig task.
__device__ __align__(16) double2 kV120MagicExpSinCos[kV120MagicLutSize];
__device__ __align__(16) double2 kV120MagicSin2[kV120MagicLutSize];

'''
t0 = t0[:pos] + magic_symbols + t0[pos:]
p0.write_text(t0, encoding='utf-8')

p4 = Path('native/src/cuda/v1/header80_backend_part04.inc')
t4 = p4.read_text(encoding='utf-8')
insert_marker = 'struct ColdServiceScratch {\n'
if insert_marker not in t4:
    raise SystemExit('prepared ColdServiceScratch marker missing')

magic_helpers = r'''
// v1.2.0 Magic LUT -----------------------------------------------------------
// For |y| >= 2^31 CUDA double sin/cos normally pays for general large-argument
// reduction. HooHash bounds |y| below roughly 2^57, so we can extract the
// periodic phase directly from a 53-bit mantissa multiplied by 128 fixed bits
// of 2/pi. No subtractive Payne-Hanek remainder is required in the hot path.

__device__ __forceinline__ bool v120_u192_any_below(
    unsigned long long high, unsigned long long middle,
    unsigned long long low, unsigned int index) {
    if (index == 0U) return false;
    if (index < 64U) {
        const unsigned long long mask = (1ULL << index) - 1ULL;
        return (low & mask) != 0ULL;
    }
    if (index == 64U) return low != 0ULL;
    if (index < 128U) {
        const unsigned int bits = index - 64U;
        const unsigned long long mask = bits == 64U ? ~0ULL : ((1ULL << bits) - 1ULL);
        return low != 0ULL || (middle & mask) != 0ULL;
    }
    if (index == 128U) return low != 0ULL || middle != 0ULL;
    const unsigned int bits = index - 128U;
    const unsigned long long mask = bits == 64U ? ~0ULL : ((1ULL << bits) - 1ULL);
    return low != 0ULL || middle != 0ULL || (high & mask) != 0ULL;
}

__device__ __forceinline__ bool v120_phase32(
    double value, unsigned int& phase) {
    constexpr double kFastBegin = 0x1p31;
    constexpr double kDomainEnd = 0x1p57;
    const double absolute = fabs(value);
    if (!(absolute >= kFastBegin && absolute < kDomainEnd) || !isfinite(value)) {
        return false;
    }

    constexpr unsigned long long kTwoOverPiHi = 0xa2f9836e4e441529ULL;
    constexpr unsigned long long kTwoOverPiLo = 0xfc2757d1f534ddc0ULL;
    constexpr unsigned long long kMantissaMask = 0x000fffffffffffffULL;

    const unsigned long long bits = static_cast<unsigned long long>(
        __double_as_longlong(absolute));
    const unsigned int biased_exponent =
        static_cast<unsigned int>((bits >> 52U) & 0x7ffULL);
    const int exponent = static_cast<int>(biased_exponent) - 1023;
    const unsigned long long mantissa =
        (1ULL << 52U) | (bits & kMantissaMask);

    // 53x128 -> 181 significant product bits stored in three 64-bit limbs.
    const unsigned long long low = mantissa * kTwoOverPiLo;
    const unsigned long long carry = __umul64hi(mantissa, kTwoOverPiLo);
    const unsigned long long middle_base = mantissa * kTwoOverPiHi;
    unsigned long long middle = middle_base + carry;
    unsigned long long high = __umul64hi(mantissa, kTwoOverPiHi);
    if (middle < middle_base) ++high;

    // t = |y| * 2/pi = product / 2^(180-exponent).
    // A full sin/cos cycle is four units of t. phase32 is therefore the low
    // 32 bits of floor(t * 2^30). For exponents 31..56 the extraction starts
    // at product bit 94..119, entirely in the middle/high limbs.
    const unsigned int shift = static_cast<unsigned int>(180 - exponent);
    const unsigned int start = shift - 30U;
    const unsigned int middle_shift = start - 64U;
    const unsigned long long window =
        (middle >> middle_shift) | (high << (64U - middle_shift));
    unsigned int raw = static_cast<unsigned int>(window & 0xffffffffULL);

    if (value < 0.0) {
        // floor(-P/2^start) = -floor(P/2^start) - (remainder != 0).
        const bool remainder = v120_u192_any_below(high, middle, low, start);
        raw = 0U - raw - static_cast<unsigned int>(remainder);
    }
    phase = raw;
    return true;
}

__device__ __forceinline__ double v120_hermite(
    const double2& a, const double2& b, double t) {
    const double t2 = t * t;
    const double t3 = t2 * t;
    const double h00 = (2.0 * t3) - (3.0 * t2) + 1.0;
    const double h10 = t3 - (2.0 * t2) + t;
    const double h01 = (-2.0 * t3) + (3.0 * t2);
    const double h11 = t3 - t2;
    return h00 * a.x + h10 * kV120MagicStep * a.y +
           h01 * b.x + h11 * kV120MagicStep * b.y;
}

__device__ __forceinline__ double v120_magic_periodic(
    double y, unsigned int region) {
    unsigned int phase = 0U;
    if (!v120_phase32(y, phase)) {
        if (region == 0U) {
            double sine, cosine;
            sincos(y, &sine, &cosine);
            return exp(sine + cosine);
        }
        if (y == kPi / 2.0 || y == 3.0 * kPi / 2.0) return 0.0;
        const double sine = sin(y);
        return sine * sine;
    }

    if (region == 1U && (y == kPi / 2.0 || y == 3.0 * kPi / 2.0)) return 0.0;

    constexpr unsigned int kFractionBits = 32U - kV120MagicLutBits;
    constexpr unsigned int kFractionMask = (1U << kFractionBits) - 1U;
    const unsigned int index = phase >> kFractionBits;
    const unsigned int next = (index + 1U) & kV120MagicLutMask;
    const double fraction = static_cast<double>(phase & kFractionMask) *
                            (1.0 / static_cast<double>(1U << kFractionBits));

    const double2 a = region == 0U
        ? kV120MagicExpSinCos[index]
        : kV120MagicSin2[index];
    const double2 b = region == 0U
        ? kV120MagicExpSinCos[next]
        : kV120MagicSin2[next];
    return v120_hermite(a, b, fraction);
}

__device__ __forceinline__ double v120_magic_rsqrt(double value, bool fast) {
    if (!fast) return 1.0 / sqrt(value);
    double r = static_cast<double>(rsqrtf(static_cast<float>(value)));
    // One FP64 Newton step. This mode is speculative; physical autotune scores
    // its exact-hash quality before it may be selected.
    r = r * (1.5 - 0.5 * value * r * r);
    return r;
}

__device__ __forceinline__ double v120_magic_nonlinear(
    double x, bool fast_rsqrt) {
    const double one_base = x * kTransformMultiplier * 0.125;
    const HooHashSelectorParts selector = decode_selector_parts(one_base);
    const double two = selector.two;
    double y;
    if (two < 0.25) y = x + (1.0 + two);
    else if (two < 0.50) y = x - (1.0 + two);
    else if (two < 0.75) y = x * (1.0 + two);
    else y = x / (1.0 + two);

    if (selector.one_region < 2U) {
        return v120_magic_periodic(y, selector.one_region);
    }
    return v120_magic_rsqrt(fabs(y) + 1.0, fast_rsqrt);
}
// ---------------------------------------------------------------------------

'''
t4 = t4.replace(insert_marker, magic_helpers + insert_marker, 1)
p4.write_text(t4, encoding='utf-8')

p6 = Path('native/src/cuda/v1/header80_backend_part06.inc')
t6 = p6.read_text(encoding='utf-8')
namespace_end = '\n\n} // namespace\n'
if namespace_end not in t6:
    raise SystemExit('anonymous namespace end marker missing')

magic_kernel = r'''

// v1.2.0 direct persistent Magic LUT engine ---------------------------------
__device__ __forceinline__ std::uint32_t v120_column_nibble(
    const std::uint32_t first_pass[8], unsigned int column) {
    const int byte_index = static_cast<int>(column >> 1U);
    const std::uint8_t packed = word_byte(first_pass, byte_index);
    return (column & 1U) == 0U
        ? static_cast<std::uint32_t>(packed >> 4U)
        : static_cast<std::uint32_t>(packed & 0x0fU);
}

__device__ __forceinline__ void v120_hoohash_magic(
    const double* __restrict__ matrix,
    std::uint32_t mix_nonce,
    const std::uint32_t first_pass[8],
    std::uint32_t mixed[8],
    bool fast_rsqrt) {
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
    double row_sum = 0.0;
    double even_sum = 0.0;

    #pragma unroll 1
    for (unsigned int cell_index = 0U; cell_index < 4096U; ++cell_index) {
        const unsigned int column = cell_index & 63U;
        const std::uint32_t nibble = v120_column_nibble(first_pass, column);
        const double value = nibble_to_double(nibble);
        const bool cold = sw_state_is_cold(sw);

        if (cold) {
            if (nibble != 0U) {
                const double x = matrix[cell_index] * hash_mod_fp64 * value + nonce_mod;
                row_sum += v120_magic_nonlinear(x, fast_rsqrt) * value * 1234.0;
            }
        } else {
#if PEPEPOW_CUDA_SCALED_MATRIX
            // 32 KiB constant-cache broadcast instead of the 512 KiB
            // scaled-nibble global table. Volta has strong FP64, so one multiply
            // is cheaper than spending HBM/L2 bandwidth on an 8-byte lookup.
            row_sum += kHeader80ScaledMatrix[cell_index] * value;
#else
            row_sum += matrix[cell_index] * 0.0001 * value;
#endif
        }
        update_sw_state(sw, row_sum);

        if ((cell_index & 63U) == 63U) {
            const unsigned int row = cell_index >> 6U;
            if ((row & 1U) == 0U) {
                even_sum = row_sum;
            } else {
                const unsigned int pair = row >> 1U;
                const std::uint64_t combined =
                    positive_double_to_u64_rz(even_sum) +
                    positive_double_to_u64_rz(row_sum);
                const std::uint32_t shift = (pair & 3U) * 8U;
                mixed[pair >> 2U] ^=
                    static_cast<std::uint32_t>(combined & 0xffU) << shift;
            }
            row_sum = 0.0;
        }
    }
}

__global__ __launch_bounds__(256, 1)
void header80_pow_magic_kernel(
    std::uint32_t first_nonce,
    const double* __restrict__ matrix,
    DeviceShareResult* __restrict__ result,
    std::size_t count,
    bool fast_rsqrt) {
    const std::size_t global_thread =
        static_cast<std::size_t>(blockIdx.x) * blockDim.x + threadIdx.x;
    const std::size_t grid_stride =
        static_cast<std::size_t>(gridDim.x) * blockDim.x;

    for (std::size_t index = global_thread; index < count; index += grid_stride) {
        const std::uint32_t nonce =
            first_nonce + static_cast<std::uint32_t>(index);
        std::uint32_t first_pass[8];
        std::uint32_t mixed[8];
        std::uint32_t final_hash[8];
        blake3_header80_words(nonce, first_pass);
        v120_hoohash_magic(
            matrix, byte_swap32(nonce), first_pass, mixed, fast_rsqrt);
        blake3_32_words(mixed, final_hash);
        if (!hash_words_meet_target(final_hash)) continue;
        if (atomicCAS(&result->found, 0U, 1U) == 0U) {
            result->nonce = nonce;
            #pragma unroll
            for (int i = 0; i < 8; ++i) result->hash_words[i] = final_hash[i];
        }
    }
}
// ---------------------------------------------------------------------------
'''
t6 = t6.replace(namespace_end, magic_kernel + namespace_end, 1)
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

    const char* v120_engine_env = std::getenv("PEPEPOW_V120_ENGINE");
    const bool v120_magic_engine =
        v120_engine_env != nullptr && std::string_view(v120_engine_env) == "magic";

    auto v120_env_u32 = [](const char* name, unsigned int fallback,
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

    const unsigned int v120_blocks_per_sm =
        v120_env_u32("PEPEPOW_V120_BLOCKS_PER_SM", 2U, 1U, 16U);
    const bool v120_fast_rsqrt =
        v120_env_u32("PEPEPOW_V120_FAST_RSQRT", 0U, 0U, 1U) != 0U;
'''
if old_geometry not in t7:
    raise SystemExit('v1.0.9 launch geometry marker missing')
t7 = t7.replace(old_geometry, new_geometry, 1)

old_cache = '''    static thread_local bool cache_configured = false;
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
new_cache = '''    static thread_local bool cache_configured = false;
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
            cudaFuncSetCacheConfig(header80_pow_magic_kernel, cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(header80 magic)");
        cache_configured = true;
    }

    if (v120_magic_engine) {
        if (threads > 256U) {
            throw std::invalid_argument(
                "v1.2.0 magic engine requires PEPEPOW_CUDA_THREADS_RUNTIME <= 256");
        }

        static thread_local int magic_lut_device = -1;
        if (magic_lut_device != device_index_) {
            std::vector<double2> exp_sincos(kV120MagicLutSize);
            std::vector<double2> sin2(kV120MagicLutSize);
            for (unsigned int i = 0U; i < kV120MagicLutSize; ++i) {
                const double theta = kV120TwoPi *
                    static_cast<double>(i) / static_cast<double>(kV120MagicLutSize);
                const double sine = std::sin(theta);
                const double cosine = std::cos(theta);
                const double f0 = std::exp(sine + cosine);
                exp_sincos[i] = make_double2(f0, f0 * (cosine - sine));
                sin2[i] = make_double2(sine * sine, 2.0 * sine * cosine);
            }
            check_cuda_header80(
                cudaMemcpyToSymbol(kV120MagicExpSinCos, exp_sincos.data(),
                                   exp_sincos.size() * sizeof(double2)),
                "cudaMemcpyToSymbol(v1.2.0 exp/sincos magic LUT)");
            check_cuda_header80(
                cudaMemcpyToSymbol(kV120MagicSin2, sin2.data(),
                                   sin2.size() * sizeof(double2)),
                "cudaMemcpyToSymbol(v1.2.0 sin2 magic LUT)");
            magic_lut_device = device_index_;
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
        const unsigned int persistent_limit =
            static_cast<unsigned int>(cached_sm_count) * v120_blocks_per_sm;
        const unsigned int magic_blocks =
            std::max(1U, std::min(blocks, persistent_limit));
        header80_pow_magic_kernel<<<magic_blocks, threads>>>(
            static_cast<std::uint32_t>(range.begin),
            static_cast<const double*>(device_matrix_),
            static_cast<DeviceShareResult*>(device_result_), count,
            v120_fast_rsqrt);
        check_cuda_header80(cudaGetLastError(), "header80_pow_magic_kernel launch");
    } else {
        header80_pow_kernel<<<blocks, threads, dynamic_shared_bytes>>>(
            static_cast<std::uint32_t>(range.begin),
            static_cast<const double*>(device_matrix_),
            static_cast<const double*>(device_scaled_nibble_),
            static_cast<DeviceShareResult*>(device_result_), count);
        check_cuda_header80(cudaGetLastError(), "header80_pow_kernel launch");
    }
'''
if old_cache not in t7:
    raise SystemExit('v1.0.9 exact launch marker missing')
t7 = t7.replace(old_cache, new_cache, 1)
p7.write_text(t7, encoding='utf-8')

main_filter = Path('native/src/app/main_v105.cpp')
main_filter_text = main_filter.read_text(encoding='utf-8')
if 'PepeW Miner v1.0.9 | Performance & Stability Edition' not in main_filter_text:
    raise SystemExit('prepared v1.0.9 console identity marker missing')
main_filter_text = main_filter_text.replace(
    'PepeW Miner v1.0.9 | Performance & Stability Edition',
    'PepeW Miner v1.2.0 | Performance & Stability Edition', 1)
main_filter.write_text(main_filter_text, encoding='utf-8')

main = Path('native/src/app/main.cpp')
mt = main.read_text(encoding='utf-8')
old_chunk = '''        // 262K keeps the optimized GPU path saturated while reducing stale-job
        // exposure to roughly half of the earlier 524K validation batch.
        constexpr std::uint64_t chunk_size = 262144;
'''
new_chunk = '''        // Runtime batch size: exact keeps the proven 262K pool cadence; the
        // v1.2.0 Magic LUT launcher can use a 1,228,800-nonce persistent batch
        // to amortize launch overhead once physical autotune proves it faster.
        std::uint64_t chunk_size = 262144ULL;
        if (const char* chunk_env = std::getenv("PEPEPOW_CHUNK_SIZE");
            chunk_env != nullptr && *chunk_env != '\\0') {
            try {
                const unsigned long long parsed = std::stoull(chunk_env);
                if (parsed < 65536ULL || parsed > 8388608ULL) {
                    throw std::invalid_argument(
                        "PEPEPOW_CHUNK_SIZE must be between 65536 and 8388608");
                }
                chunk_size = static_cast<std::uint64_t>(parsed);
            } catch (const std::invalid_argument&) {
                throw;
            } catch (...) {
                throw std::invalid_argument("PEPEPOW_CHUNK_SIZE must be an integer");
            }
        }
'''
if old_chunk not in mt:
    raise SystemExit('main chunk marker missing')
mt = mt.replace(old_chunk, new_chunk, 1)
main.write_text(mt, encoding='utf-8')

cmake = Path('native/CMakeLists.txt')
ct = cmake.read_text(encoding='utf-8')
if 'project(PepePowMiner VERSION 1.0.9 LANGUAGES C CXX)' not in ct:
    raise SystemExit('prepared v1.0.9 CMake version marker missing')
ct = ct.replace(
    'project(PepePowMiner VERSION 1.0.9 LANGUAGES C CXX)',
    'project(PepePowMiner VERSION 1.2.0 LANGUAGES C CXX)', 1)
old_target = '''        add_executable(pepepow_v100_autotune tests/v100_geometry_benchmark.cpp)
        target_link_libraries(pepepow_v100_autotune PRIVATE pepepow_core pepepow_cuda)
        set_target_properties(pepepow_v100_autotune PROPERTIES LINKER_LANGUAGE CUDA CUDA_RESOLVE_DEVICE_SYMBOLS ON)
'''
new_target = old_target + '''        add_executable(pepepow_v120_autotune tests/v120_magic_benchmark.cpp)
        target_link_libraries(pepepow_v120_autotune PRIVATE pepepow_core pepepow_cuda)
        set_target_properties(pepepow_v120_autotune PROPERTIES LINKER_LANGUAGE CUDA CUDA_RESOLVE_DEVICE_SYMBOLS ON)
'''
if old_target not in ct:
    raise SystemExit('v1.0.9 autotune CMake marker missing')
ct = ct.replace(old_target, new_target, 1)
cmake.write_text(ct, encoding='utf-8')

# Structural gates before NVCC is even invoked.
v0 = p0.read_text(encoding='utf-8')
v4 = p4.read_text(encoding='utf-8')
v6 = p6.read_text(encoding='utf-8')
v7 = p7.read_text(encoding='utf-8')
assert 'kV120MagicExpSinCos' in v0 and 'kV120MagicSin2' in v0
assert 'v120_phase32' in v4 and 'v120_hermite' in v4
assert 'v120_magic_nonlinear' in v4
assert 'header80_pow_magic_kernel' in v6
assert 'kHeader80ScaledMatrix[cell_index] * value' in v6
assert 'cudaMemcpyToSymbol(kV120MagicExpSinCos' in v7
assert 'PEPEPOW_V120_ENGINE' in v7
assert 'PEPEPOW_V120_FAST_RSQRT' in v7
assert 'PEPEPOW_CHUNK_SIZE' in main.read_text(encoding='utf-8')
assert 'PepeW Miner v1.2.0 | Performance & Stability Edition' in main_filter.read_text(encoding='utf-8')
assert 'project(PepePowMiner VERSION 1.2.0 LANGUAGES C CXX)' in cmake.read_text(encoding='utf-8')
assert 'pepepow_v120_autotune' in cmake.read_text(encoding='utf-8')
print('V120_MAGIC_LUT_PREPARE=PASS')
