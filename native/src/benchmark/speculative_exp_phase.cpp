#include "pepepow/crypto/blake3.hpp"
#include "pepepow/crypto/hoohash_reference.hpp"

#include <array>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <limits>
#include <vector>

namespace {
constexpr double kPi = 3.141592653589793238462643383279502884;
constexpr double kTwoPi = 2.0 * kPi;
constexpr double kEpsilon = 1e-9;
constexpr double kTransformMultiplier = 0.000001;

std::uint32_t load_be32(const std::uint8_t* p) {
    return (std::uint32_t(p[0]) << 24U) | (std::uint32_t(p[1]) << 16U) |
           (std::uint32_t(p[2]) << 8U) | std::uint32_t(p[3]);
}
std::uint32_t load_le32(const std::uint8_t* p) {
    return std::uint32_t(p[0]) | (std::uint32_t(p[1]) << 8U) |
           (std::uint32_t(p[2]) << 16U) | (std::uint32_t(p[3]) << 24U);
}
void store_be32(std::uint8_t* p, std::uint32_t x) {
    p[0]=std::uint8_t(x>>24U); p[1]=std::uint8_t(x>>16U); p[2]=std::uint8_t(x>>8U); p[3]=std::uint8_t(x);
}

struct PhaseLut {
    std::vector<double> values;
    explicit PhaseLut(std::size_t bins) : values(bins + 1U) {
        for (std::size_t i=0;i<=bins;++i) {
            const double phase = -kPi + kTwoPi * double(i) / double(bins);
            values[i] = std::exp(std::sin(phase) + std::cos(phase));
        }
    }
    double eval(double x) const {
        double phase = std::remainder(x, kTwoPi);
        if (phase < -kPi) phase += kTwoPi;
        if (phase >  kPi) phase -= kTwoPi;
        const double pos=(phase+kPi)*double(values.size()-1U)/kTwoPi;
        std::size_t i=std::size_t(pos);
        if (i>=values.size()-1U) i=values.size()-2U;
        const double f=pos-double(i);
        return values[i]+(values[i+1U]-values[i])*f;
    }
};

double fast_complex(double x,const PhaseLut& lut) {
    const double one=x*kTransformMultiplier/8.0-std::floor(x*kTransformMultiplier/8.0);
    const double two=x*kTransformMultiplier/4.0-std::floor(x*kTransformMultiplier/4.0);
    const int path=two<0.25?0:two<0.50?1:two<0.75?2:3;
    const double arg=path==0?x+1.0+two:path==1?x-1.0-two:path==2?x*(1.0+two):x/(1.0+two);
    if (one<0.33) return lut.eval(arg);
    if (one<0.66) {
        if (std::fabs(arg-kPi/2.0)<kEpsilon || std::fabs(arg-3.0*kPi/2.0)<kEpsilon) return 0.0;
        const double s=std::sin(arg); return s*s;
    }
    return 1.0/std::sqrt(std::fabs(arg)+1.0);
}

double fast_for_complex(double input,const PhaseLut& lut) {
    double rounds=1.0;
    const double transformed=fast_complex(input,lut);
    while (std::isnan(transformed)||std::isinf(transformed)) {
        input*=0.1;
        if (input<=1e-13) return 0.0;
        rounds+=1.0;
    }
    return transformed*rounds;
}

pepepow::crypto::Hash256 fast_mix(const pepepow::crypto::HoohashMatrix& matrix,
                                  const pepepow::crypto::Hash256& first,
                                  std::uint64_t nonce,const PhaseLut& lut) {
    std::array<std::uint8_t,64> vector{};
    std::array<double,64> product{};
    std::uint32_t hash_mod{};
    for (std::size_t i=0;i<8;++i) hash_mod^=load_be32(first.data()+i*4U);
    for (std::size_t i=0;i<32;++i) { vector[i*2U]=first[i]>>4U; vector[i*2U+1U]=first[i]&0x0fU; }
    double sw=0.0;
    const double nonce_mod=double(nonce&0xffU);
    for (std::size_t i=0;i<64;++i) {
        for (std::size_t j=0;j<64;++j) {
            if (sw<=0.02) {
                const double input=matrix[i][j]*double(hash_mod)*double(vector[j])+nonce_mod;
                product[i]+=fast_for_complex(input,lut)*double(vector[j])*1234.0;
            } else {
                product[i]+=matrix[i][j]*0.0001*double(vector[j]);
            }
            sw=product[i]/1024.0-std::floor(product[i]/1024.0);
        }
    }
    pepepow::crypto::Hash256 mixed{};
    for (std::size_t i=0;i<32;++i) {
        const auto p=std::uint64_t(product[i*2U])+std::uint64_t(product[i*2U+1U]);
        mixed[i]=first[i]^std::uint8_t(p&0xffU);
    }
    return mixed;
}

bool relaxed_hit(const pepepow::crypto::Hash256& h,std::uint8_t threshold) {
    return h[0] <= threshold;
}
}

int main(int argc,char** argv) {
    std::uint32_t samples=4096;
    std::size_t bins=4096;
    std::uint32_t threshold=15;
    if (argc>1) samples=std::uint32_t(std::strtoul(argv[1],nullptr,10));
    if (argc>2) bins=std::size_t(std::strtoull(argv[2],nullptr,10));
    if (argc>3) threshold=std::uint32_t(std::strtoul(argv[3],nullptr,10));
    if (samples==0 || bins<64 || threshold>255) return 2;

    std::array<std::uint8_t,80> header{
        0x00,0x40,0x00,0x20,0xdf,0x13,0xf8,0xc7,0x24,0x3b,0x6b,0x22,0x6c,0x33,0x99,0xf4,
        0x85,0xe9,0x02,0x34,0x7e,0x41,0xba,0x37,0x0e,0x0c,0x8f,0xea,0x75,0x67,0x2f,0x45,
        0x01,0x00,0x00,0x00,0x22,0xda,0x19,0x46,0xe7,0xdb,0xa6,0x53,0x52,0xae,0x0f,0x65,
        0xce,0x77,0xdc,0xff,0x51,0x05,0xe2,0xf4,0x6a,0x44,0x3e,0x3a,0x86,0xbb,0x35,0x9b,
        0xb6,0x78,0x8b,0xf9,0x62,0xa2,0x41,0x6a,0x33,0xce,0x01,0x1d,0x4d,0x94,0xe7,0x55};
    auto masked=header; masked[76]=masked[77]=masked[78]=masked[79]=0;
    const auto matrix=pepepow::crypto::generate_hoohash_matrix(pepepow::crypto::blake3_hash(masked));
    const std::uint32_t start=0x4d94e755U;
    PhaseLut lut(bins);

    std::uint64_t strict_hits=0,fast_hits=0,tp=0,fn=0,fp=0;
    std::vector<pepepow::crypto::Hash256> firsts(samples);
    std::vector<std::uint32_t> nonces(samples);
    for (std::uint32_t n=0;n<samples;++n) {
        auto h=header; store_be32(h.data()+76,start+n);
        firsts[n]=pepepow::crypto::blake3_hash(h);
        nonces[n]=load_le32(h.data()+76);
    }

    std::vector<pepepow::crypto::Hash256> strict_hashes(samples),fast_hashes(samples);
    const auto s0=std::chrono::steady_clock::now();
    for (std::uint32_t n=0;n<samples;++n)
        strict_hashes[n]=pepepow::crypto::blake3_hash(pepepow::crypto::hoohash_matrix_mix(matrix,firsts[n],nonces[n]));
    const auto s1=std::chrono::steady_clock::now();
    for (std::uint32_t n=0;n<samples;++n)
        fast_hashes[n]=pepepow::crypto::blake3_hash(fast_mix(matrix,firsts[n],nonces[n],lut));
    const auto s2=std::chrono::steady_clock::now();

    for (std::uint32_t n=0;n<samples;++n) {
        const bool sh=relaxed_hit(strict_hashes[n],std::uint8_t(threshold));
        const bool fh=relaxed_hit(fast_hashes[n],std::uint8_t(threshold));
        strict_hits+=sh; fast_hits+=fh;
        if (sh&&fh) ++tp; else if (sh) ++fn; else if (fh) ++fp;
    }
    const double strict_s=std::chrono::duration<double>(s1-s0).count();
    const double fast_s=std::chrono::duration<double>(s2-s1).count();
    const double recall=strict_hits?double(tp)/double(strict_hits):1.0;
    const double precision=fast_hits?double(tp)/double(fast_hits):1.0;
    const double strict_rate=double(samples)/strict_s;
    const double fast_rate=double(samples)/fast_s;
    const double gain=fast_rate/strict_rate-1.0;

    std::cout<<std::setprecision(17)
             <<"{\"schema\":1,\"candidate\":\"spec-exp-phase-lut\",\"fixed_job\":\"real-block-kat-0x4734dd\""
             <<",\"samples\":"<<samples<<",\"bins\":"<<bins<<",\"relaxed_first_byte_max\":"<<threshold
             <<",\"strict_hits\":"<<strict_hits<<",\"fast_hits\":"<<fast_hits<<",\"true_positives\":"<<tp
             <<",\"false_negatives\":"<<fn<<",\"false_positives\":"<<fp<<",\"recall\":"<<recall
             <<",\"precision\":"<<precision<<",\"strict_hashes_per_s\":"<<strict_rate
             <<",\"fast_hashes_per_s\":"<<fast_rate<<",\"throughput_gain\":"<<gain
             <<",\"strict_validated_submissions\":"<<tp<<",\"invalid_submissions_after_strict_validation\":0}\n";
    return 0;
}
