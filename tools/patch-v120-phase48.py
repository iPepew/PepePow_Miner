from pathlib import Path

p = Path('native/src/cuda/v1/header80_backend_part04.inc')
t = p.read_text(encoding='utf-8')

old_sig = '''__device__ __forceinline__ bool v120_phase32(
    double value, unsigned int& phase) {'''
new_sig = '''__device__ __forceinline__ bool v120_phase48(
    double value, unsigned long long& phase) {'''
if old_sig not in t:
    raise SystemExit('v120 phase32 signature marker missing')
t = t.replace(old_sig, new_sig, 1)

old_extract = '''    // t = |y| * 2/pi = product / 2^(180-exponent).
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
'''
new_extract = '''    // t = |y| * 2/pi = product / 2^(180-exponent).
    // A full sin/cos cycle is four units of t. Keep 48 phase bits:
    // 16 select one of 65,536 nodes and 32 become the Hermite fraction.
    // phase48 = low 48 bits of floor(t * 2^46). For HooHash exponents
    // 31..56 the extraction begins at product bit 78..103.
    const unsigned int shift = static_cast<unsigned int>(180 - exponent);
    const unsigned int start = shift - 46U;
    const unsigned int middle_shift = start - 64U;
    const unsigned long long window =
        (middle >> middle_shift) | (high << (64U - middle_shift));
    constexpr unsigned long long kPhaseMask = 0x0000ffffffffffffULL;
    unsigned long long raw = window & kPhaseMask;

    if (value < 0.0) {
        // floor(-P/2^start) = -floor(P/2^start) - (remainder != 0).
        const bool remainder = v120_u192_any_below(high, middle, low, start);
        raw = (0ULL - raw - static_cast<unsigned long long>(remainder)) & kPhaseMask;
    }
    phase = raw;
'''
if old_extract not in t:
    raise SystemExit('v120 phase extraction marker missing')
t = t.replace(old_extract, new_extract, 1)

old_use = '''    unsigned int phase = 0U;
    if (!v120_phase32(y, phase)) {'''
new_use = '''    unsigned long long phase = 0ULL;
    if (!v120_phase48(y, phase)) {'''
if old_use not in t:
    raise SystemExit('v120 periodic phase use marker missing')
t = t.replace(old_use, new_use, 1)

old_fraction = '''    constexpr unsigned int kFractionBits = 32U - kV120MagicLutBits;
    constexpr unsigned int kFractionMask = (1U << kFractionBits) - 1U;
    const unsigned int index = phase >> kFractionBits;
    const unsigned int next = (index + 1U) & kV120MagicLutMask;
    const double fraction = static_cast<double>(phase & kFractionMask) *
                            (1.0 / static_cast<double>(1U << kFractionBits));
'''
new_fraction = '''    constexpr unsigned int kFractionBits = 32U;
    constexpr unsigned long long kFractionMask = 0xffffffffULL;
    const unsigned int index = static_cast<unsigned int>(phase >> kFractionBits) &
                               kV120MagicLutMask;
    const unsigned int next = (index + 1U) & kV120MagicLutMask;
    const double fraction = static_cast<double>(phase & kFractionMask) *
                            (1.0 / 4294967296.0);
'''
if old_fraction not in t:
    raise SystemExit('v120 phase fraction marker missing')
t = t.replace(old_fraction, new_fraction, 1)

p.write_text(t, encoding='utf-8')

# prepare-v120-magic-lut.py contains C++ snippets in normal Python triple-quoted
# strings. A C++ '\0' literal is interpreted by Python as a real NUL unless it
# is double escaped. Sanitize generated text here before NVCC sees it.
for generated in (
    Path('native/src/cuda/v1/header80_backend_part07.inc'),
    Path('native/src/app/main.cpp'),
):
    data = generated.read_bytes()
    if b'\x00' in data:
        generated.write_bytes(data.replace(b'\x00', b'\\0'))

verify = p.read_text(encoding='utf-8')
assert 'v120_phase48' in verify
assert 'v120_phase32' not in verify
assert '0x0000ffffffffffffULL' in verify
assert '1.0 / 4294967296.0' in verify
for generated in (
    Path('native/src/cuda/v1/header80_backend_part07.inc'),
    Path('native/src/app/main.cpp'),
):
    assert b'\x00' not in generated.read_bytes()
print('V120_PHASE48_PATCH=PASS')
