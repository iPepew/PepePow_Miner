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
#include <stdexcept>
#include <string_view>

namespace {
constexpr double kPi=3.14159265358979323846, kMul=0.000001;
std::uint8_t hn(char c){if(c>='0'&&c<='9')return c-'0';if(c>='a'&&c<='f')return c-'a'+10;if(c>='A'&&c<='F')return c-'A'+10;throw std::invalid_argument("hex");}
template<size_t N> std::array<std::uint8_t,N> ph(std::string_view s){std::array<std::uint8_t,N>a{};for(size_t i=0;i<N;i++)a[i]=(hn(s[2*i])<<4)|hn(s[2*i+1]);return a;}
void le32(std::uint8_t*p,std::uint32_t v){p[0]=v;p[1]=v>>8;p[2]=v>>16;p[3]=v>>24;}
std::uint32_t be32(const std::uint8_t*p){return (std::uint32_t(p[0])<<24)|(std::uint32_t(p[1])<<16)|(std::uint32_t(p[2])<<8)|p[3];}
double med(double x){return std::exp(std::sin(x)+std::cos(x));}
double mid(double x){if(x==kPi/2||x==3*kPi/2)return 0;double s=std::sin(x);return s*s;}
double hi(double x){return 1/std::sqrt(std::fabs(x)+1);}
double nl(double x){double one=x*kMul/8-std::floor(x*kMul/8),two=x*kMul/4-std::floor(x*kMul/4),y; if(two<.25)y=x+(1+two);else if(two<.5)y=x-(1+two);else if(two<.75)y=x*(1+two);else y=x/(1+two);return one<.33?med(y):(one<.66?mid(y):hi(y));}
double safe(double x){double r=1,o=nl(x);while(std::isnan(o)||std::isinf(o)){x*=.1;if(x<=1e-13)return 0;r++;o=nl(x);}return o*r;}
struct C{std::uint64_t cells=0,linear=0,nonlinear=0,risk_rows=0,risk_cells=0;std::array<std::uint64_t,8> thr{},wrap{};std::uint64_t suffix_sum=0;};
}
int main(int argc,char**argv){
 std::uint32_t n=8192;if(argc>1)n=std::strtoul(argv[1],nullptr,10);if(!n)return 2;
 constexpr std::string_view hx="004000206857ad8097ae27f653ff45b867b80e7de26d89f5ca91435a088a1f6200000000941cfbf2fc87b80ebc90c37b217ade46a9279726e6d0ea9cc1ff93d8d059fc8a013f676afb24011d00064cd5";
 auto base=ph<80>(hx),masked=base;std::fill(masked.begin()+76,masked.end(),0);auto seed=pepepow::crypto::blake3_hash(masked);auto m=pepepow::crypto::generate_hoohash_matrix(seed);
 constexpr std::array<double,8> bands={1e-2,5e-3,1e-3,5e-4,1e-4,1e-5,1e-6,1e-7}; C c;
 for(std::uint32_t nonce=0;nonce<n;nonce++){
  auto h=base;le32(h.data()+76,nonce);auto fp=pepepow::crypto::blake3_hash(h);std::array<std::uint8_t,64>v{};std::uint32_t hm=0;for(size_t i=0;i<8;i++)hm^=be32(fp.data()+4*i);for(size_t i=0;i<32;i++){v[2*i]=fp[i]>>4;v[2*i+1]=fp[i]&15;}
  double sw=0,nm=double(nonce&255);
  for(size_t i=0;i<64;i++){
   double p=0,fast=0,bound=0;bool row_risk=false;size_t first=64;
   for(size_t j=0;j<64;j++){
    if(sw<=.02){c.nonlinear++;if(v[j]){double in=m[i][j]*double(hm)*double(v[j])+nm;double x=safe(in)*double(v[j])*1234;p+=x;fast+=x;}}
    else {c.linear++;double ex=m[i][j]*.0001*double(v[j]),ap=double(float(ex));p+=ex;fast+=ap;bound+=std::fabs(ex-ap)+8*std::numeric_limits<double>::epsilon()*(std::fabs(ex)+1);}
    c.cells++;sw=p/1024-std::floor(p/1024);double dthr=std::fabs(sw-.02),dwrap=std::min(sw,1-sw);for(size_t b=0;b<bands.size();b++){if(dthr<=bands[b])c.thr[b]++;if(dwrap<=bands[b])c.wrap[b]++;}
    double e=bound/1024;bool risk=e>0&&(dthr<=e||dwrap<=e);if(risk){c.risk_cells++;if(!row_risk){row_risk=true;first=j;}}
   }
   if(row_risk){c.risk_rows++;c.suffix_sum+=64-first;}
  }
 }
 std::cout<<std::fixed<<std::setprecision(6)<<"job=accepted-header80-fixed-matrix\nnonces="<<n<<"\ncells="<<c.cells<<"\nlinear_cells="<<c.linear<<"\nnonlinear_cells="<<c.nonlinear<<"\nrisk_rows="<<c.risk_rows<<"\nrisk_row_pct="<<100.0*c.risk_rows/(double(n)*64)<<"\nrisk_cells="<<c.risk_cells<<"\nrisk_cell_pct="<<100.0*c.risk_cells/double(c.cells)<<"\nmean_suffix_cells_if_replay="<<(c.risk_rows?double(c.suffix_sum)/c.risk_rows:0)<<'\n';
 for(size_t b=0;b<bands.size();b++)std::cout<<"band="<<bands[b]<<" threshold_pct="<<100.0*c.thr[b]/c.cells<<" wrap_pct="<<100.0*c.wrap[b]/c.cells<<'\n';
}
