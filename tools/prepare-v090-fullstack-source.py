from pathlib import Path
import sys

if len(sys.argv) != 3:
    raise SystemExit("usage: prepare-v090-fullstack-source.py SOURCE MODE")

path = Path(sys.argv[1])
tokens = {x for x in sys.argv[2].split("+") if x and x != "base"}
text = path.read_text(encoding="utf-8")

schedule = [
    [0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15],
    [2,6,3,10,7,0,4,13,1,11,12,5,9,14,15,8],
    [3,4,10,12,13,2,7,14,6,5,9,0,11,15,8,1],
    [10,7,12,9,14,3,13,15,4,0,11,2,5,8,1,6],
    [12,13,9,11,15,10,14,8,7,2,5,3,0,1,6,4],
    [9,14,11,5,8,12,15,1,13,3,0,10,2,6,4,7],
    [11,15,5,0,1,9,8,6,14,10,2,12,3,4,7,13],
]
g_calls = [
    (0,4,8,12,0,1), (1,5,9,13,2,3),
    (2,6,10,14,4,5), (3,7,11,15,6,7),
    (0,5,10,15,8,9), (1,6,11,12,10,11),
    (2,7,8,13,12,13), (3,4,9,14,14,15),
]

def direct_blake_function(header: bool) -> str:
    lines = []
    if header:
        lines += [
            "__device__ __forceinline__ void blake3_header80_words(",
            "    std::uint32_t nonce, std::uint32_t output[8]) {",
            "    const std::uint32_t m0 = kHeader80TailWords[0];",
            "    const std::uint32_t m1 = kHeader80TailWords[1];",
            "    const std::uint32_t m2 = kHeader80TailWords[2];",
            "    const std::uint32_t m3 = byte_swap32(nonce);",
        ]
        for i in range(4, 16):
            lines.append(f"    constexpr std::uint32_t m{i} = 0U;")
        for i in range(8):
            lines.append(f"    std::uint32_t v{i} = kHeader80Midstate[{i}];")
        block_len = 16
        flags = "kChunkEnd | kRoot"
    else:
        lines += [
            "__device__ __forceinline__ void blake3_32_words(",
            "    const std::uint32_t input[8], std::uint32_t output[8]) {",
        ]
        for i in range(8):
            lines.append(f"    const std::uint32_t m{i} = input[{i}];")
        for i in range(8, 16):
            lines.append(f"    constexpr std::uint32_t m{i} = 0U;")
        for i in range(8):
            lines.append(f"    std::uint32_t v{i} = kHeader80Iv[{i}];")
        block_len = 32
        flags = "kChunkStart | kChunkEnd | kRoot"
    for i in range(4):
        lines.append(f"    std::uint32_t v{8+i} = kHeader80Iv[{i}];")
    lines += [
        "    std::uint32_t v12 = 0U;",
        "    std::uint32_t v13 = 0U;",
        f"    std::uint32_t v14 = {block_len}U;",
        f"    std::uint32_t v15 = {flags};",
        "",
    ]
    for r, s in enumerate(schedule):
        lines.append(f"    // BLAKE3 round {r}")
        for a,b,c,d,x,y in g_calls:
            lines.append(
                f"    g(v{a}, v{b}, v{c}, v{d}, m{s[x]}, m{s[y]});")
    lines.append("")
    for i in range(8):
        lines.append(f"    output[{i}] = v{i} ^ v{i+8};")
    lines.append("}")
    return "\n".join(lines)

if "hwfrac" in tokens:
    start = text.find("struct HooHashSelectorParts {")
    end = text.find("__device__ __forceinline__ double safe_nonlinear", start)
    if start < 0 or end < 0:
        raise SystemExit("ERROR: selector-combined block not found")
    replacement = r'''struct HooHashSelectorParts {
    unsigned int one_region;
    double two;
};

__device__ __forceinline__ HooHashSelectorParts decode_selector_parts(
    double one_base) {
    // Consensus bound: one_base is non-negative and below 2^34.
    // The integer conversion and subtraction are therefore exact.
    const unsigned long long integral = __double2ull_rz(one_base);
    const double one = one_base - __ull2double_rn(integral);
    double two = one + one;
    if (two >= 1.0) two -= 1.0;
    const unsigned int one_region =
        one < 0.33 ? 0U : (one < 0.66 ? 1U : 2U);
    return {one_region, two};
}

__device__ __forceinline__ double nonlinear(double x) {
    const double one_base = x * kTransformMultiplier * 0.125;
    const HooHashSelectorParts selector = decode_selector_parts(one_base);
    const double two = selector.two;
    double y;
    if (two < 0.25) y = x + (1.0 + two);
    else if (two < 0.50) y = x - (1.0 + two);
    else if (two < 0.75) y = x * (1.0 + two);
    else y = x / (1.0 + two);
    if (selector.one_region == 0U) {
        double sine, cosine;
        sincos(y, &sine, &cosine);
        return exp(sine + cosine);
    }
    if (selector.one_region == 1U) {
        if (y == kPi / 2.0 || y == 3.0 * kPi / 2.0) return 0.0;
        const double sine = sin(y);
        return sine * sine;
    }
    return 1.0 / sqrt(fabs(y) + 1.0);
}

'''
    text = text[:start] + replacement + text[end:]

if "blakedirect" in tokens:
    start = text.find("__device__ __forceinline__ void compress_words(")
    end = text.find("__device__ __forceinline__ double positive_fraction(", start)
    if start < 0 or end < 0:
        raise SystemExit("ERROR: BLAKE3 compression block not found")
    replacement = direct_blake_function(True) + "\n\n" + direct_blake_function(False) + "\n\n"
    text = text[:start] + replacement + text[end:]
else:
    if "blake8" in tokens:
        old = r'''__device__ __forceinline__ void compress_words(
    const std::uint32_t cv[8], const std::uint32_t block[16],
    std::uint32_t block_len, std::uint32_t flags, std::uint32_t out[16]) {'''
        new = r'''__device__ __forceinline__ void compress_words(
    const std::uint32_t cv[8], const std::uint32_t block[16],
    std::uint32_t block_len, std::uint32_t flags, std::uint32_t out[8]) {'''
        if text.count(old) != 1:
            raise SystemExit(f"ERROR: compress signature count={text.count(old)}")
        text = text.replace(old, new, 1)
        old_out = r'''    #pragma unroll
    for (int i = 0; i < 8; ++i) {
        out[i] = v[i] ^ v[i + 8];
        out[i + 8] = v[i + 8] ^ cv[i];
    }'''
        new_out = r'''    #pragma unroll
    for (int i = 0; i < 8; ++i) {
        out[i] = v[i] ^ v[i + 8];
    }'''
        if text.count(old_out) != 1:
            raise SystemExit(f"ERROR: compress output block count={text.count(old_out)}")
        text = text.replace(old_out, new_out, 1)
        count = text.count("std::uint32_t compressed[16];")
        if count != 2:
            raise SystemExit(f"ERROR: compressed array count={count}")
        text = text.replace("std::uint32_t compressed[16];",
                            "std::uint32_t compressed[8];")

    if "cvelide" in tokens:
        header_cv = r'''    std::uint32_t cv[8];
    std::uint32_t block[16];
    std::uint32_t compressed[8];
    #pragma unroll
    for (int i = 0; i < 8; ++i) cv[i] = kHeader80Midstate[i];'''
        header_new = r'''    std::uint32_t block[16];
    std::uint32_t compressed[8];'''
        final_cv = r'''    std::uint32_t cv[8];
    std::uint32_t block[16];
    std::uint32_t compressed[8];
    #pragma unroll
    for (int i = 0; i < 8; ++i) cv[i] = kHeader80Iv[i];'''
        final_new = r'''    std::uint32_t block[16];
    std::uint32_t compressed[8];'''
        if text.count(header_cv) != 1 or text.count(final_cv) != 1:
            raise SystemExit("ERROR: cv-elide caller blocks not found")
        text = text.replace(header_cv, header_new, 1)
        text = text.replace(final_cv, final_new, 1)
        if text.count("compress_words(cv, block, 16, kChunkEnd | kRoot, compressed);") != 1:
            raise SystemExit("ERROR: header compress call not found")
        if text.count("compress_words(cv, block, 32, kChunkStart | kChunkEnd | kRoot, compressed);") != 1:
            raise SystemExit("ERROR: final compress call not found")
        text = text.replace(
            "compress_words(cv, block, 16, kChunkEnd | kRoot, compressed);",
            "compress_words(kHeader80Midstate, block, 16, kChunkEnd | kRoot, compressed);", 1)
        text = text.replace(
            "compress_words(cv, block, 32, kChunkStart | kChunkEnd | kRoot, compressed);",
            "compress_words(kHeader80Iv, block, 32, kChunkStart | kChunkEnd | kRoot, compressed);", 1)

if "inplace" in tokens:
    old = r'''    std::uint32_t first_pass[8];
    std::uint32_t mixed[8];
    std::uint32_t final_hash[8];
    blake3_header80_words(nonce, first_pass);
    hoohash_mix_words(matrix, scaled_nibble_table, byte_swap32(nonce), first_pass, mixed);
    blake3_32_words(mixed, final_hash);
    if (!hash_words_meet_target(final_hash)) return;
    if (atomicCAS(&result->found, 0U, 1U) == 0U) {
        result->nonce = nonce;
        #pragma unroll
        for (int i = 0; i < 8; ++i) result->hash_words[i] = final_hash[i];
    }'''
    new = r'''    std::uint32_t first_pass[8];
    std::uint32_t mixed[8];
    blake3_header80_words(nonce, first_pass);
    hoohash_mix_words(matrix, scaled_nibble_table, byte_swap32(nonce), first_pass, mixed);
    blake3_32_words(mixed, mixed);
    if (!hash_words_meet_target(mixed)) return;
    if (atomicCAS(&result->found, 0U, 1U) == 0U) {
        result->nonce = nonce;
        #pragma unroll
        for (int i = 0; i < 8; ++i) result->hash_words[i] = mixed[i];
    }'''
    if text.count(old) != 1:
        raise SystemExit(f"ERROR: monolithic final block count={text.count(old)}")
    text = text.replace(old, new, 1)

if "constcold" in tokens and "ldgcold" in tokens:
    raise SystemExit("ERROR: constcold and ldgcold are mutually exclusive")

if "constcold" in tokens:
    old = "            const double cell = matrix[cell_index];"
    new = "            const double cell = kHeader80ScaledMatrix[cell_index];"
    if text.count(old) != 1:
        raise SystemExit(f"ERROR: cold matrix load count={text.count(old)}")
    text = text.replace(old, new, 1)
    old_copy = r'''cudaMemcpyToSymbol(kHeader80ScaledMatrix, scaled_matrix.data(),
                               kMatrixElements * sizeof(double), 0, cudaMemcpyHostToDevice)'''
    new_copy = r'''cudaMemcpyToSymbol(kHeader80ScaledMatrix, matrix.data()->data(),
                               kMatrixElements * sizeof(double), 0, cudaMemcpyHostToDevice)'''
    if text.count(old_copy) != 1:
        raise SystemExit(f"ERROR: constant matrix copy count={text.count(old_copy)}")
    text = text.replace(old_copy, new_copy, 1)

if "ldgcold" in tokens:
    old = "            const double cell = matrix[cell_index];"
    new = "            const double cell = __ldg(matrix + cell_index);"
    if text.count(old) != 1:
        raise SystemExit(f"ERROR: cold matrix load count={text.count(old)}")
    text = text.replace(old, new, 1)

path.write_text(text, encoding="utf-8")
