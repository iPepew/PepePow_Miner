        bits & ((1ULL << fractional_width) - 1ULL);
    return (remainder << (58U - fractional_width)) <=
           kThresholdSignificand;
}

#if PEPEPOW_CUDA_SW_STATE_MODE == 0
using HooHashSwState = double;
__device__ __forceinline__ HooHashSwState initial_sw_state() { return 0.0; }
__device__ __forceinline__ bool sw_state_is_cold(HooHashSwState state) {
    return state <= 0.02;
}
__device__ __forceinline__ void update_sw_state(
    HooHashSwState& state, double sum) {
    state = positive_fraction_div1024_bits(sum);
}
#elif PEPEPOW_CUDA_SW_STATE_MODE == 1
using HooHashSwState = bool;
__device__ __forceinline__ HooHashSwState initial_sw_state() { return true; }
__device__ __forceinline__ bool sw_state_is_cold(HooHashSwState state) {
    return state;
}
__device__ __forceinline__ void update_sw_state(
    HooHashSwState& state, double sum) {
    state = positive_fraction_div1024_bits(sum) <= 0.02;
}
#elif PEPEPOW_CUDA_SW_STATE_MODE == 2
using HooHashSwState = bool;
__device__ __forceinline__ HooHashSwState initial_sw_state() { return true; }
__device__ __forceinline__ bool sw_state_is_cold(HooHashSwState state) {
    return state;
}
__device__ __forceinline__ void update_sw_state(
    HooHashSwState& state, double sum) {
    state = positive_fraction_div1024_le_002_exact(sum);
}
#else
using HooHashSwState = bool;
__device__ __forceinline__ HooHashSwState initial_sw_state() { return true; }
__device__ __forceinline__ bool sw_state_is_cold(HooHashSwState state) {
    return state;
}
__device__ __forceinline__ void update_sw_state(
    HooHashSwState& state, double sum) {
    // Exact for the positive finite HooHash row-sum range: scaling by 2^-10,
    // round-down conversion, and the integer-to-double conversion preserve the
    // consensus predicate while avoiding the generic fractional-bit decoder.
    const double scaled = sum * 0x1.0p-10;
    const unsigned long long whole = __double2ull_rd(scaled);
    state = (scaled - static_cast<double>(whole)) <= 0.02;
}
#endif

__device__ __forceinline__ std::uint64_t positive_double_to_u64_rz(double value) {
#if PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS
    const std::uint64_t bits = static_cast<std::uint64_t>(__double_as_longlong(value));
    const unsigned int exponent = static_cast<unsigned int>((bits >> 52U) & 0x7ffU);
    if (exponent < 1023U) return 0U;
    const unsigned int integer_bits = exponent - 1023U;
    if (integer_bits >= 64U || exponent == 0x7ffU) {
        return static_cast<std::uint64_t>(__double2ull_rz(value));
    }
    const std::uint64_t significand =
        (std::uint64_t{1} << 52U) | (bits & kDoubleMantissaMask);
    if (integer_bits >= 52U) return significand << (integer_bits - 52U);
    return significand >> (52U - integer_bits);
#else
    return static_cast<std::uint64_t>(value);
#endif
}

__device__ __forceinline__ void g(
    std::uint32_t& a, std::uint32_t& b, std::uint32_t& c, std::uint32_t& d,
    std::uint32_t mx, std::uint32_t my) {
    a = a + b + mx;
    d = rotr32(d ^ a, 16);
    c += d;
    b = rotr32(b ^ c, 12);
    a = a + b + my;
    d = rotr32(d ^ a, 8);
    c += d;
    b = rotr32(b ^ c, 7);
}

__device__ __forceinline__ void compress_words(
    const std::uint32_t cv[8], const std::uint32_t block[16],
    std::uint32_t block_len, std::uint32_t flags, std::uint32_t out[16]) {
    std::uint32_t v[16];
    #pragma unroll
    for (int i = 0; i < 8; ++i) v[i] = cv[i];
    #pragma unroll
    for (int i = 0; i < 4; ++i) v[8 + i] = kHeader80Iv[i];
    v[12] = 0;
    v[13] = 0;
    v[14] = block_len;
    v[15] = flags;

    #pragma unroll
    for (int round = 0; round < 7; ++round) {
        const std::uint8_t* s = kHeader80Schedule[round];
        g(v[0],v[4],v[8],v[12],block[s[0]],block[s[1]]);
        g(v[1],v[5],v[9],v[13],block[s[2]],block[s[3]]);
        g(v[2],v[6],v[10],v[14],block[s[4]],block[s[5]]);
        g(v[3],v[7],v[11],v[15],block[s[6]],block[s[7]]);
        g(v[0],v[5],v[10],v[15],block[s[8]],block[s[9]]);
        g(v[1],v[6],v[11],v[12],block[s[10]],block[s[11]]);
        g(v[2],v[7],v[8],v[13],block[s[12]],block[s[13]]);
        g(v[3],v[4],v[9],v[14],block[s[14]],block[s[15]]);
    }

    #pragma unroll
    for (int i = 0; i < 8; ++i) {
        out[i] = v[i] ^ v[i + 8];
        out[i + 8] = v[i + 8] ^ cv[i];
    }
}

__device__ __forceinline__ void blake3_header80_words(
    std::uint32_t nonce, std::uint32_t output[8]) {
    std::uint32_t cv[8];
    std::uint32_t block[16];
    std::uint32_t compressed[16];
    #pragma unroll
    for (int i = 0; i < 8; ++i) cv[i] = kHeader80Midstate[i];
    #pragma unroll
    for (int i = 0; i < 16; ++i) block[i] = 0;
    block[0] = kHeader80TailWords[0];
    block[1] = kHeader80TailWords[1];
    block[2] = kHeader80TailWords[2];
    block[3] = byte_swap32(nonce);
    compress_words(cv, block, 16, kChunkEnd | kRoot, compressed);
    #pragma unroll
    for (int i = 0; i < 8; ++i) output[i] = compressed[i];
}

__device__ __forceinline__ void blake3_32_words(
    const std::uint32_t input[8], std::uint32_t output[8]) {
    std::uint32_t cv[8];
    std::uint32_t block[16];
    std::uint32_t compressed[16];
    #pragma unroll
    for (int i = 0; i < 8; ++i) cv[i] = kHeader80Iv[i];
    #pragma unroll
    for (int i = 0; i < 8; ++i) block[i] = input[i];
    #pragma unroll
    for (int i = 8; i < 16; ++i) block[i] = 0;
    compress_words(cv, block, 32, kChunkStart | kChunkEnd | kRoot, compressed);
    #pragma unroll
    for (int i = 0; i < 8; ++i) output[i] = compressed[i];
}

#if defined(PEPEPOW_CUDA_FINAL_BLAKE_STATE_COMPRESSION) && PEPEPOW_CUDA_FINAL_BLAKE_STATE_COMPRESSION
// Exact 32-byte BLAKE3 path for the overwhelmingly common target-reject case.
// It removes cv/block/compressed/final_hash array overlap: the 16-word
// compression state is compared and, only for a winning share, published
// directly. Message words 8..15 are protocol-defined zeroes.
__device__ __forceinline__ std::uint32_t blake3_32_message_word(
    const std::uint32_t* __restrict__ input, std::uint32_t index) {
    return index < 8U ? input[index] : 0U;
}

__device__ __forceinline__ void blake3_32_check_and_publish(
    const std::uint32_t* __restrict__ input, std::uint32_t nonce,
    DeviceShareResult* __restrict__ result) {
    std::uint32_t v[16];
    #pragma unroll
    for (int i = 0; i < 8; ++i) v[i] = kHeader80Iv[i];
    #pragma unroll
    for (int i = 0; i < 4; ++i) v[8 + i] = kHeader80Iv[i];
    v[12] = 0U;
    v[13] = 0U;
    v[14] = 32U;
    v[15] = kChunkStart | kChunkEnd | kRoot;

    #pragma unroll
    for (int round = 0; round < 7; ++round) {
        const std::uint8_t* s = kHeader80Schedule[round];
        g(v[0],v[4],v[8],v[12],blake3_32_message_word(input,s[0]),blake3_32_message_word(input,s[1]));
        g(v[1],v[5],v[9],v[13],blake3_32_message_word(input,s[2]),blake3_32_message_word(input,s[3]));
        g(v[2],v[6],v[10],v[14],blake3_32_message_word(input,s[4]),blake3_32_message_word(input,s[5]));
        g(v[3],v[7],v[11],v[15],blake3_32_message_word(input,s[6]),blake3_32_message_word(input,s[7]));
        g(v[0],v[5],v[10],v[15],blake3_32_message_word(input,s[8]),blake3_32_message_word(input,s[9]));
        g(v[1],v[6],v[11],v[12],blake3_32_message_word(input,s[10]),blake3_32_message_word(input,s[11]));
        g(v[2],v[7],v[8],v[13],blake3_32_message_word(input,s[12]),blake3_32_message_word(input,s[13]));
        g(v[3],v[4],v[9],v[14],blake3_32_message_word(input,s[14]),blake3_32_message_word(input,s[15]));
    }

    #pragma unroll
    for (int i = 0; i < 8; ++i) {
        const std::uint32_t hash_be = byte_swap32(v[i] ^ v[i + 8]);
        const std::uint32_t target_be = kHeader80TargetWords[i];
        if (hash_be < target_be) break;
        if (hash_be > target_be) return;
    }
    if (atomicCAS(&result->found, 0U, 1U) == 0U) {
        result->nonce = nonce;
        #pragma unroll
        for (int i = 0; i < 8; ++i) result->hash_words[i] = v[i] ^ v[i + 8];
    }
}
#endif

__device__ __forceinline__ double positive_fraction(double value) {
#if PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS
    return positive_fraction_bits(value);
#elif PEPEPOW_CUDA_FAST_FRACTION
    if (value >= 0x1.0p52) return 0.0;
    return value - static_cast<double>(__double2ull_rz(value));
#else
    return value - floor(value);
#endif
}

struct HooHashSelectorParts {
    unsigned int one_region;
    double two;
};

__device__ __forceinline__ HooHashSelectorParts decode_selector_parts(
    double one_base) {
    const std::uint64_t bits =
        static_cast<std::uint64_t>(__double_as_longlong(one_base));
    const unsigned int exponent =
        static_cast<unsigned int>((bits >> 52U) & 0x7ffULL);
    constexpr std::uint64_t kBits033 = 0x3fd51eb851eb851fULL;
    constexpr std::uint64_t kBits066 = 0x3fe51eb851eb851fULL;
