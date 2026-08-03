from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit("usage: prepare-v100-sw32-source.py SOURCE")

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
begin = "__device__ __forceinline__ bool\npositive_fraction_div1024_le_002_finite"
end = "#if PEPEPOW_CUDA_SW_STATE_MODE == 0"
start = text.find(begin)
stop = text.find(end, start)
if start < 0 or stop < 0:
    raise SystemExit(
        f"ERROR: SW predicate markers not found: begin={start} end={stop}")

replacement = r'''__device__ __forceinline__ bool
positive_fraction_div1024_le_002_finite(double value) {
    const std::uint64_t bits =
        static_cast<std::uint64_t>(__double_as_longlong(value));
    constexpr std::uint64_t kScaledThresholdBits = 0x40347ae147ae147bULL;
    if (bits <= kScaledThresholdBits) return true;

    const unsigned int exponent =
        static_cast<unsigned int>((bits >> 52U) & 0x7ffULL);
    if (exponent < 1033U) return false;
    const unsigned int integer_bits = exponent - 1033U;
    if (integer_bits >= 52U) return true;

    if (integer_bits <= 12U) {
        const std::uint32_t high =
            static_cast<std::uint32_t>(bits >> 32U) &
            (0x000fffffU >> integer_bits);
        const std::uint32_t low = static_cast<std::uint32_t>(bits);
        const std::uint32_t threshold_high =
            0x000051ebU >> integer_bits;
        const std::uint32_t threshold_low = __funnelshift_r(
            0x851eb851U, 0x000051ebU, integer_bits);
        if (high < threshold_high) return true;
        if (high > threshold_high) return false;
        return low <= threshold_low;
    }

    const unsigned int fractional_width = 52U - integer_bits;
    const std::uint64_t remainder =
        bits & ((1ULL << fractional_width) - 1ULL);
    constexpr std::uint64_t kThresholdSignificand = 5764607523034235ULL;
    return (remainder << (58U - fractional_width)) <=
           kThresholdSignificand;
}

'''
text = text[:start] + replacement + text[stop:]
path.write_text(text, encoding="utf-8")
