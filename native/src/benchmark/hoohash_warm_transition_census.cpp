#include "pepepow/crypto/blake3.hpp"
#include "pepepow/crypto/hoohash_reference.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdlib>
#include <iomanip>
#include <iostream>
#include <limits>
#include <numeric>
#include <stdexcept>
#include <string_view>
#include <vector>

namespace {
using pepepow::crypto::HoohashMatrix;
constexpr std::size_t kRows=64, kCols=64, kNibbles=16;
constexpr int kQBits=20;
constexpr std::int64_t kQScale=std::int64_t{1}<<kQBits;
constexpr std::int64_t kQPeriod=kQScale*1024;
constexpr std::int64_t kQColdThreshold=(kQPeriod*2)/100;
constexpr double kPi=3.14159265358979323846;
constexpr double kTransformMultiplier=0.000001;

std::uint8_t hex_nibble(char v){
    if(v>='0'&&v<='9') return static_cast<std::uint8_t>(v-'0');
    if(v>='a'&&v<='f') return static_cast<std::uint8_t>(v-'a'+10);
    if(v>='A'&&v<='F') return static_cast<std::uint8_t>(v-'A'+10);
    throw std::invalid_argument("invalid hex digit");
}
template<std::size_t N> std::array<std::uint8_t,N> parse_hex(std::string_view s){
    if(s.size()!=N*2U) throw std::invalid_argument("unexpected hex length");
    std::array<std::uint8_t,N> out{};
    for(std::size_t i=0;i<N;++i) out[i]=static_cast<std::uint8_t>((hex_nibble(s[i*2])<<4U)|hex_nibble(s[i*2+1]));
    return out;
}
void store_le32(std::uint8_t* p,std::uint32_t v){p[0]=v;p[1]=v>>8;p[2]=v>>16;p[3]=v>>24;}
std::uint32_t load_be32(const std::uint8_t* p){return (std::uint32_t(p[0])<<24)|(std::uint32_t(p[1])<<16)|(std::uint32_t(p[2])<<8)|std::uint32_t(p[3]);}

double nonlinear(double x){
    const double one_base=x*kTransformMultiplier/8.0;
    const double two_base=x*kTransformMultiplier/4.0;
    const double one=one_base-std::floor(one_base);
    const double two=two_base-std::floor(two_base);
    double y;
    if(two<0.25) y=x+(1.0+two);
    else if(two<0.50) y=x-(1.0+two);
    else if(two<0.75) y=x*(1.0+two);
    else y=x/(1.0+two);
    if(one<0.33) return std::exp(std::sin(y)+std::cos(y));
    if(one<0.66){ if(y==kPi/2.0||y==3.0*kPi/2.0) return 0.0; const double s=std::sin(y); return s*s; }
    return 1.0/std::sqrt(std::fabs(y)+1.0);
}
double safe_nonlinear(double x){
    double rounds=1.0,out=nonlinear(x);
    while(std::isnan(out)||std::isinf(out)){x*=0.1;if(x<=1e-13)return 0.0;rounds+=1.0;out=nonlinear(x);} return out*rounds;
}
struct Table {
    std::vector<std::int32_t> v;
    explicit Table(const HoohashMatrix& m):v(kRows*kCols*kNibbles){
        for(std::size_t r=0;r<kRows;++r) for(std::size_t c=0;c<kCols;++c) for(std::size_t n=0;n<kNibbles;++n){
            const double x=m[r][c]*0.0001*double(n)*double(kQScale);
            v[(r*kCols+c)*kNibbles+n]=static_cast<std::int32_t>(std::llround(x));
        }
    }
    std::int32_t get(std::size_t r,std::size_t c,std::uint8_t n)const{return v[(r*kCols+c)*kNibbles+n];}
};
std::uint64_t percentile(std::vector<std::uint32_t> x,double q){
    if(x.empty()) return 0; std::sort(x.begin(),x.end()); const std::size_t i=std::min<std::size_t>(x.size()-1,static_cast<std::size_t>(q*double(x.size()-1))); return x[i];
}
}

int main(int argc,char** argv){
    std::uint32_t nonce_count=4096U;
    if(argc>1) nonce_count=static_cast<std::uint32_t>(std::strtoul(argv[1],nullptr,10));
    if(nonce_count==0U) return 2;
    constexpr std::string_view kHeader=
        "004000206857ad8097ae27f653ff45b867b80e7de26d89f5ca91435a088a1f6200000000"
        "941cfbf2fc87b80ebc90c37b217ade46a9279726e6d0ea9cc1ff93d8d059fc8a"
        "013f676afb24011d00064cd5";
    auto base=parse_hex<80>(kHeader); auto masked=base; std::fill(masked.begin()+76,masked.end(),0U);
    const auto seed=pepepow::crypto::blake3_hash(masked); const auto matrix=pepepow::crypto::generate_hoohash_matrix(seed); const Table table(matrix);

    std::uint64_t total_cells=0,cold_cells=0,warm_cells=0,warm_to_cold=0,cold_to_warm=0,warm_runs=0;
    std::uint64_t delta_neg=0,delta_zero=0,delta_pos=0;
    std::int64_t delta_min=std::numeric_limits<std::int64_t>::max(),delta_max=std::numeric_limits<std::int64_t>::min();
    std::uint64_t warm_pair_cells=0,warm_quad_cells=0;
    std::vector<std::uint32_t> runs; runs.reserve(nonce_count*64U);

    for(std::uint32_t nonce=0;nonce<nonce_count;++nonce){
        auto h=base; store_le32(h.data()+76,nonce); const auto first=pepepow::crypto::blake3_hash(h);
        std::array<std::uint8_t,64> vec{}; for(std::size_t i=0;i<32;++i){vec[i*2]=first[i]>>4U;vec[i*2+1]=first[i]&0x0fU;}
        std::uint32_t hash_mod=0; for(std::size_t i=0;i<8;++i) hash_mod^=load_be32(first.data()+i*4U);
        const double nonce_mod=double(nonce&0xffU); bool cold=true; std::uint32_t current_run=0;
        for(std::size_t r=0;r<kRows;++r){
            std::int64_t qsum=0;
            for(std::size_t c=0;c<kCols;++c){
                ++total_cells; const bool before=cold; const std::uint8_t nib=vec[c];
                if(before){
                    ++cold_cells;
                    if(current_run){runs.push_back(current_run);++warm_runs;current_run=0;}
                    if(nib){const double val=double(nib);const double x=matrix[r][c]*double(hash_mod)*val+nonce_mod;const double contrib=safe_nonlinear(x)*val*1234.0;qsum+=static_cast<std::int64_t>(std::llround(contrib*double(kQScale)));}
                }else{
                    ++warm_cells; ++current_run;
                    const std::int64_t d=table.get(r,c,nib); qsum+=d;
                    delta_min=std::min(delta_min,d);delta_max=std::max(delta_max,d); if(d<0)++delta_neg;else if(d>0)++delta_pos;else ++delta_zero;
                }
                const std::int64_t rem=qsum%kQPeriod; cold=rem<=kQColdThreshold;
                if(before&&!cold) ++cold_to_warm; if(!before&&cold) ++warm_to_cold;
            }
        }
        if(current_run){runs.push_back(current_run);++warm_runs;}
    }
    for(auto n:runs){ if(n>=2) warm_pair_cells+=n-(n%2U); if(n>=4) warm_quad_cells+=n-(n%4U); }
    const double mean=runs.empty()?0.0:double(std::accumulate(runs.begin(),runs.end(),std::uint64_t{0}))/double(runs.size());
    const auto max_run=runs.empty()?0U:*std::max_element(runs.begin(),runs.end());
    std::cout<<std::fixed<<std::setprecision(6)
      <<"job=accepted-header80-fixed-matrix\n"
      <<"profile=q20_warm_transition_census\n"
      <<"nonces="<<nonce_count<<"\n"
      <<"total_cells="<<total_cells<<"\n"
      <<"cold_cells="<<cold_cells<<"\n"
      <<"warm_cells="<<warm_cells<<"\n"
      <<"warm_pct="<<(100.0*double(warm_cells)/double(total_cells))<<"\n"
      <<"cold_to_warm="<<cold_to_warm<<"\n"
      <<"warm_to_cold="<<warm_to_cold<<"\n"
      <<"warm_runs="<<warm_runs<<"\n"
      <<"warm_run_mean="<<mean<<"\n"
      <<"warm_run_p50="<<percentile(runs,0.50)<<"\n"
      <<"warm_run_p90="<<percentile(runs,0.90)<<"\n"
      <<"warm_run_p95="<<percentile(runs,0.95)<<"\n"
      <<"warm_run_p99="<<percentile(runs,0.99)<<"\n"
      <<"warm_run_max="<<max_run<<"\n"
      <<"warm_pair_coverage_pct="<<(warm_cells?100.0*double(warm_pair_cells)/double(warm_cells):0.0)<<"\n"
      <<"warm_quad_coverage_pct="<<(warm_cells?100.0*double(warm_quad_cells)/double(warm_cells):0.0)<<"\n"
      <<"delta_min="<<delta_min<<"\n"
      <<"delta_max="<<delta_max<<"\n"
      <<"delta_negative="<<delta_neg<<"\n"
      <<"delta_zero="<<delta_zero<<"\n"
      <<"delta_positive="<<delta_pos<<"\n"
      <<"v100_allowed=false\n";
    return 0;
}
