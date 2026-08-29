#include "pepepow/crypto/blake3.hpp"
#include "pepepow/crypto/hoohash_reference.hpp"

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <limits>

namespace {
constexpr double kPi = 3.14159265358979323846;
constexpr double kEpsilon = 1e-9;
constexpr double kTransformMultiplier = 0.000001;

struct Range {
    double lo = std::numeric_limits<double>::infinity();
    double hi = -std::numeric_limits<double>::infinity();
    void add(double x) { if (x < lo) lo = x; if (x > hi) hi = x; }
};

struct Census {
    std::uint64_t nonlinear_calls{};
    std::uint64_t medium{};
    std::uint64_t intermediate{};
    std::uint64_t high{};
    std::array<std::uint64_t,4> apply_path{};
    std::uint64_t cold_cells{};
    std::uint64_t linear_cells{};
    Range medium_arg, intermediate_arg, high_arg;
};

std::uint32_t load_be32(const std::uint8_t* p) {
    return (std::uint32_t(p[0]) << 24U) | (std::uint32_t(p[1]) << 16U) |
           (std::uint32_t(p[2]) << 8U) | std::uint32_t(p[3]);
}

std::uint32_t load_le32(const std::uint8_t* p) {
    return std::uint32_t(p[0]) | (std::uint32_t(p[1]) << 8U) |
           (std::uint32_t(p[2]) << 16U) | (std::uint32_t(p[3]) << 24U);
}

void store_be32(std::uint8_t* p, std::uint32_t x) {
    p[0]=std::uint8_t(x>>24U); p[1]=std::uint8_t(x>>16U);
    p[2]=std::uint8_t(x>>8U); p[3]=std::uint8_t(x);
}

double profiled_complex(double x, Census& c) {
    ++c.nonlinear_calls;
    const double one = x * kTransformMultiplier / 8.0 - std::floor(x * kTransformMultiplier / 8.0);
    const double two = x * kTransformMultiplier / 4.0 - std::floor(x * kTransformMultiplier / 4.0);
    int path = two < 0.25 ? 0 : two < 0.50 ? 1 : two < 0.75 ? 2 : 3;
    ++c.apply_path[std::size_t(path)];
    double arg = path == 0 ? x + 1.0 + two :
                 path == 1 ? x - 1.0 - two :
                 path == 2 ? x * (1.0 + two) : x / (1.0 + two);
    if (one < 0.33) {
        ++c.medium; c.medium_arg.add(arg);
        return std::exp(std::sin(arg) + std::cos(arg));
    }
    if (one < 0.66) {
        ++c.intermediate; c.intermediate_arg.add(arg);
        if (std::fabs(arg-kPi/2.0)<kEpsilon || std::fabs(arg-3.0*kPi/2.0)<kEpsilon) return 0.0;
        const double s=std::sin(arg); return s*s;
    }
    ++c.high; c.high_arg.add(arg);
    return 1.0/std::sqrt(std::fabs(arg)+1.0);
}

double profiled_for_complex(double input, Census& c) {
    double rounds=1.0;
    const double transformed=profiled_complex(input,c);
    while (std::isnan(transformed) || std::isinf(transformed)) {
        input*=0.1;
        if (input<=1e-13) return 0.0;
        rounds+=1.0;
    }
    return transformed*rounds;
}

pepepow::crypto::Hash256 profiled_mix(const pepepow::crypto::HoohashMatrix& matrix,
                                      const pepepow::crypto::Hash256& first,
                                      std::uint64_t nonce, Census& c) {
    std::array<std::uint8_t,64> vector{};
    std::array<double,64> product{};
    std::uint32_t hash_mod{};
    for (std::size_t i=0;i<8;++i) hash_mod ^= load_be32(first.data()+i*4);
    for (std::size_t i=0;i<32;++i) { vector[i*2]=first[i]>>4U; vector[i*2+1]=first[i]&0x0fU; }
    double sw=0.0;
    const double nonce_mod=double(nonce&0xffU);
    for (std::size_t i=0;i<64;++i) {
        for (std::size_t j=0;j<64;++j) {
            if (sw<=0.02) {
                ++c.cold_cells;
                const double input=matrix[i][j]*double(hash_mod)*double(vector[j])+nonce_mod;
                product[i]+=profiled_for_complex(input,c)*double(vector[j])*1234.0;
            } else {
                ++c.linear_cells;
                product[i]+=matrix[i][j]*0.0001*double(vector[j]);
            }
            sw=product[i]/1024.0-std::floor(product[i]/1024.0);
        }
    }
    pepepow::crypto::Hash256 mixed{};
    for (std::size_t i=0;i<32;++i) {
        const auto p=std::uint64_t(product[i*2])+std::uint64_t(product[i*2+1]);
        mixed[i]=first[i]^std::uint8_t(p&0xffU);
    }
    return mixed;
}

void print_range(const char* name,const Range& r) {
    std::cout << "\""<<name<<"\":{";
    if (std::isfinite(r.lo)) std::cout << "\"min\":"<<r.lo<<",\"max\":"<<r.hi;
    else std::cout << "\"min\":null,\"max\":null";
    std::cout << "}";
}
}

int main(int argc,char** argv) {
    std::uint32_t samples=256;
    if (argc>1) samples=std::uint32_t(std::strtoul(argv[1],nullptr,10));
    if (samples==0) return 2;

    pepepow::crypto::Header80 header{
        0x00,0x40,0x00,0x20,0xdf,0x13,0xf8,0xc7,0x24,0x3b,0x6b,0x22,0x6c,0x33,0x99,0xf4,
        0x85,0xe9,0x02,0x34,0x7e,0x41,0xba,0x37,0x0e,0x0c,0x8f,0xea,0x75,0x67,0x2f,0x45,
        0x01,0x00,0x00,0x00,0x22,0xda,0x19,0x46,0xe7,0xdb,0xa6,0x53,0x52,0xae,0x0f,0x65,
        0xce,0x77,0xdc,0xff,0x51,0x05,0xe2,0xf4,0x6a,0x44,0x3e,0x3a,0x86,0xbb,0x35,0x9b,
        0xb6,0x78,0x8b,0xf9,0x62,0xa2,0x41,0x6a,0x33,0xce,0x01,0x1d,0x4d,0x94,0xe7,0x55};
    auto masked=header; masked[76]=masked[77]=masked[78]=masked[79]=0;
    const auto matrix_seed=pepepow::crypto::blake3_hash(masked);
    const auto matrix=pepepow::crypto::generate_hoohash_matrix(matrix_seed);
    const std::uint32_t start=0x4d94e755U;
    Census c{};
    std::uint64_t mismatches{};
    for (std::uint32_t n=0;n<samples;++n) {
        auto h=header; store_be32(h.data()+76,start+n);
        const auto first=pepepow::crypto::blake3_hash(h);
        const auto nonce=load_le32(h.data()+76);
        const auto strict=pepepow::crypto::hoohash_matrix_mix(matrix,first,nonce);
        const auto observed=profiled_mix(matrix,first,nonce,c);
        if (strict!=observed) ++mismatches;
    }
    const double total=double(c.nonlinear_calls);
    std::cout<<std::setprecision(17);
    std::cout<<"{\"schema\":1,\"fixed_job\":\"real-block-kat-0x4734dd\",\"samples\":"<<samples
             <<",\"mismatches\":"<<mismatches<<",\"nonlinear_calls\":"<<c.nonlinear_calls
             <<",\"cold_cells\":"<<c.cold_cells<<",\"linear_cells\":"<<c.linear_cells
             <<",\"branches\":{\"exp_sin_cos\":"<<c.medium<<",\"sin2\":"<<c.intermediate
             <<",\"inv_sqrt\":"<<c.high<<"},\"branch_fraction\":{\"exp_sin_cos\":"<<(total?c.medium/total:0.0)
             <<",\"sin2\":"<<(total?c.intermediate/total:0.0)<<",\"inv_sqrt\":"<<(total?c.high/total:0.0)
             <<"},\"apply_path\":["<<c.apply_path[0]<<","<<c.apply_path[1]<<","<<c.apply_path[2]<<","<<c.apply_path[3]<<"],\"ranges\":{";
    print_range("exp_sin_cos",c.medium_arg); std::cout<<","; print_range("sin2",c.intermediate_arg); std::cout<<","; print_range("inv_sqrt",c.high_arg);
    std::cout<<"}}\n";
    return mismatches==0 ? 0 : 3;
}
