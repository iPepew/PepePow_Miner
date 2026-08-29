from pathlib import Path
import re

p = Path('native/src/benchmark/hoohash_speculative_q20_cuda.cu')
s = p.read_text(encoding='utf-8')

replacements = [
    ('constexpr std::int64_t kQScale = std::int64_t{1} << kQBits;', 'constexpr std::uint64_t kQScale = std::uint64_t{1} << kQBits;'),
    ('constexpr std::int64_t kQPeriod = kQScale * 1024;', 'constexpr std::uint64_t kQPeriod = kQScale * 1024ULL;\nconstexpr std::uint64_t kQPeriodMask = kQPeriod - 1ULL;\nstatic_assert((kQPeriod & (kQPeriod - 1ULL)) == 0ULL);'),
    ('constexpr std::int64_t kQColdThreshold = (kQPeriod * 2) / 100;', 'constexpr std::uint64_t kQColdThreshold = (kQPeriod * 2ULL) / 100ULL;'),
    ('const int row=pair*2+rr; std::int64_t qsum=0;', 'const int row=pair*2+rr; std::uint64_t qsum=0;'),
    ('qsum+=static_cast<std::int64_t>(floor(c*static_cast<double>(kQScale)+0.5));', 'qsum+=static_cast<std::uint64_t>(floor(c*static_cast<double>(kQScale)+0.5));'),
    ('const std::int64_t rem=qsum%kQPeriod;', 'const std::uint64_t rem=qsum & kQPeriodMask;'),
    ('floors[rr]=static_cast<std::uint64_t>(qsum/kQScale);', 'floors[rr]=qsum >> kQBits;'),
    ('std::vector<double> flat(4096); std::vector<std::int32_t> qtable(4096*16);', 'std::vector<double> flat(4096); std::vector<std::int32_t> qtable(4096);'),
    ('for(int r=0;r<64;++r)for(int c=0;c<64;++c){flat[r*64+c]=matrix[r][c];for(int n=0;n<16;++n){const double x=matrix[r][c]*0.0001*static_cast<double>(n)*static_cast<double>(kQScale);qtable[(r*64+c)*16+n]=static_cast<std::int32_t>(std::llround(x));}}', 'for(int r=0;r<64;++r)for(int c=0;c<64;++c){flat[r*64+c]=matrix[r][c];const double x=matrix[r][c]*0.0001*static_cast<double>(kQScale);qtable[r*64+c]=static_cast<std::int32_t>(std::llround(x));}'),
]
for old, new in replacements:
    if old in s:
        s = s.replace(old, new, 1)
    elif new not in s:
        raise SystemExit(f'missing coefficient marker: {old}')

warm_re = re.compile(r'qsum\s*\+=\s*static_cast<std::(?:u?int64_t)>\(table\[\(row\*64\+col\)\*16\+static_cast<int>\(nib\)\]\);')
warm_new = 'qsum+=static_cast<std::uint64_t>(static_cast<std::int64_t>(table[row*64+col])*static_cast<std::int64_t>(nib));'
if warm_new not in s:
    s, count = warm_re.subn(warm_new, s, count=1)
    if count != 1:
        raise SystemExit('warm coefficient marker missing')

start = s.index('__device__ __forceinline__ void q20_mix(')
loop = s.index('            #pragma unroll 1\n            for (int col=0;col<64;++col) {', start)
end_marker = '            floors[rr]=qsum >> kQBits;'
end = s.index(end_marker, loop)
new_loop = """            #pragma unroll 1
            for (int col=0;col<64;) {
                const std::uint8_t b=byte_at(first,col>>1);
                const std::uint32_t nib=(col&1)?(b&0x0fU):(b>>4U);
                if (!cold && col+1<64) {
                    const std::uint64_t d0=static_cast<std::uint64_t>(static_cast<std::int64_t>(table[row*64+col])*static_cast<std::int64_t>(nib));
                    const int col1=col+1;
                    const std::uint8_t b1=byte_at(first,col1>>1);
                    const std::uint32_t nib1=(col1&1)?(b1&0x0fU):(b1>>4U);
                    const std::uint64_t d1=static_cast<std::uint64_t>(static_cast<std::int64_t>(table[row*64+col1])*static_cast<std::int64_t>(nib1));
                    const std::uint64_t rem0=qsum & kQPeriodMask;
                    const std::uint64_t room=kQPeriodMask-rem0;
                    const std::uint64_t dsum=d0+d1;
                    if (dsum<=room) {
                        qsum+=dsum;
                        col+=2;
                        continue;
                    }
                }
                if (cold) {
                    if (nib!=0U) {
                        const double val=static_cast<double>(nib);
                        const double x=matrix[row*64+col]*static_cast<double>(hash_mod)*val+nonce_mod;
                        const double c=safe_nonlinear(x)*val*1234.0;
                        qsum+=static_cast<std::uint64_t>(floor(c*static_cast<double>(kQScale)+0.5));
                    }
                } else {
                    qsum+=static_cast<std::uint64_t>(static_cast<std::int64_t>(table[row*64+col])*static_cast<std::int64_t>(nib));
                }
                const std::uint64_t rem=qsum & kQPeriodMask;
                cold=rem<=kQColdThreshold;
                ++col;
            }
"""
s = s[:loop] + new_loop + s[end:]
p.write_text(s, encoding='utf-8')
