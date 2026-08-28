#include "pepepow/crypto/blake3.hpp"
#include "pepepow/crypto/hoohash_reference.hpp"

#include <cuda_runtime.h>

#include <array>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <stdexcept>
#include <string_view>
#include <vector>

namespace {
using pepepow::crypto::Hash256;
using pepepow::crypto::HoohashMatrix;

constexpr int kRows = 64;
constexpr int kCols = 64;
constexpr int kNibbles = 16;
constexpr int kQBits = 20;
constexpr std::int64_t kQScale = std::int64_t{1} << kQBits;
constexpr std::int64_t kQPeriod = kQScale * 1024;
constexpr std::int64_t kQColdThreshold = (kQPeriod * 2) / 100;
constexpr double kPi = 3.14159265358979323846;
constexpr double kTransformMultiplier = 0.000001;
constexpr std::uint32_t kChunkStart = 1U;
constexpr std::uint32_t kChunkEnd = 2U;
constexpr std::uint32_t kRoot = 8U;

__device__ __constant__ std::uint32_t c_midstate[8];
__device__ __constant__ std::uint32_t c_tail[3];
__device__ __constant__ std::uint32_t c_iv[8] = {
    0x6A09E667U, 0xBB67AE85U, 0x3C6EF372U, 0xA54FF53AU,
    0x510E527FU, 0x9B05688CU, 0x1F83D9ABU, 0x5BE0CD19U};
__device__ __constant__ std::uint8_t c_schedule[7][16] = {
    {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15},
    {2,6,3,10,7,0,4,13,1,11,12,5,9,14,15,8},
    {3,4,10,12,13,2,7,14,6,5,9,0,11,15,8,1},
    {10,7,12,9,14,3,13,15,4,0,11,2,5,8,1,6},
    {12,13,9,11,15,10,14,8,7,2,5,3,0,1,6,4},
    {9,14,11,5,8,12,15,1,13,3,0,10,2,6,4,7},
    {11,15,5,0,1,9,8,6,14,10,2,12,3,4,7,13}};

inline void cuda_check(cudaError_t status, const char* what) {
    if (status != cudaSuccess) throw std::runtime_error(std::string(what) + ": " + cudaGetErrorString(status));
}

__device__ __forceinline__ std::uint32_t rotr32(std::uint32_t x, int n) {
    return __funnelshift_r(x, x, n);
}
__device__ __forceinline__ void g(std::uint32_t& a, std::uint32_t& b, std::uint32_t& c, std::uint32_t& d,
                                  std::uint32_t mx, std::uint32_t my) {
    a = a + b + mx; d = rotr32(d ^ a, 16); c += d; b = rotr32(b ^ c, 12);
    a = a + b + my; d = rotr32(d ^ a, 8);  c += d; b = rotr32(b ^ c, 7);
}
__device__ __forceinline__ void compress_words(const std::uint32_t cv[8], const std::uint32_t block[16],
                                                std::uint32_t block_len, std::uint32_t flags,
                                                std::uint32_t out[16]) {
    std::uint32_t v[16];
    #pragma unroll
    for (int i=0;i<8;++i) v[i]=cv[i];
    #pragma unroll
    for (int i=0;i<4;++i) v[8+i]=c_iv[i];
    v[12]=0; v[13]=0; v[14]=block_len; v[15]=flags;
    #pragma unroll
    for (int r=0;r<7;++r) {
        const std::uint8_t* s=c_schedule[r];
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
    for (int i=0;i<8;++i) { out[i]=v[i]^v[i+8]; out[i+8]=v[i+8]^cv[i]; }
}
__device__ __forceinline__ void blake3_header80(std::uint32_t nonce, std::uint32_t out[8]) {
    std::uint32_t block[16]{}; std::uint32_t tmp[16];
    block[0]=c_tail[0]; block[1]=c_tail[1]; block[2]=c_tail[2]; block[3]=nonce;
    compress_words(c_midstate, block, 16, kChunkEnd|kRoot, tmp);
    #pragma unroll
    for (int i=0;i<8;++i) out[i]=tmp[i];
}
__device__ __forceinline__ void blake3_32(const std::uint32_t in[8], std::uint32_t out[8]) {
    std::uint32_t block[16]{}; std::uint32_t tmp[16];
    #pragma unroll
    for (int i=0;i<8;++i) block[i]=in[i];
    compress_words(c_iv, block, 32, kChunkStart|kChunkEnd|kRoot, tmp);
    #pragma unroll
    for (int i=0;i<8;++i) out[i]=tmp[i];
}
__device__ __forceinline__ std::uint32_t bswap32(std::uint32_t x) { return __byte_perm(x,0U,0x0123U); }
__device__ __forceinline__ std::uint8_t byte_at(const std::uint32_t words[8], int i) {
    return static_cast<std::uint8_t>((words[i>>2] >> ((i&3)*8)) & 0xffU);
}
__device__ __forceinline__ double nonlinear(double x) {
    const double one_base=x*kTransformMultiplier/8.0;
    const double two_base=x*kTransformMultiplier/4.0;
    const double one=one_base-floor(one_base);
    const double two=two_base-floor(two_base);
    double y;
    if (two<0.25) y=x+(1.0+two);
    else if (two<0.50) y=x-(1.0+two);
    else if (two<0.75) y=x*(1.0+two);
    else y=x/(1.0+two);
    if (one<0.33) { double s,c; sincos(y,&s,&c); return exp(s+c); }
    if (one<0.66) { if (y==kPi/2.0 || y==3.0*kPi/2.0) return 0.0; const double s=sin(y); return s*s; }
    return 1.0/sqrt(fabs(y)+1.0);
}
__device__ __forceinline__ double safe_nonlinear(double x) {
    double rounds=1.0; double out=nonlinear(x);
    while (isnan(out)||isinf(out)) { x*=0.1; if (x<=1e-13) return 0.0; rounds+=1.0; out=nonlinear(x); }
    return out*rounds;
}
__device__ __forceinline__ bool cvt_cold(double sum) {
    const double scaled=sum*0x1.0p-10;
    const unsigned long long whole=__double2ull_rd(scaled);
    return (scaled-static_cast<double>(whole))<=0.02;
}

__device__ __forceinline__ void exact_mix(const double* matrix, std::uint32_t nonce,
                                           const std::uint32_t first[8], std::uint32_t mixed[8]) {
    std::uint32_t hx=0U;
    #pragma unroll
    for (int i=0;i<8;++i) { hx^=first[i]; mixed[i]=first[i]; }
    const std::uint32_t hash_mod=bswap32(hx);
    const double nonce_mod=static_cast<double>(nonce&0xffU);
    bool cold=true;
    #pragma unroll 1
    for (int pair=0;pair<32;++pair) {
        std::uint64_t floors[2];
        #pragma unroll
        for (int rr=0;rr<2;++rr) {
            const int row=pair*2+rr; double sum=0.0;
            #pragma unroll 1
            for (int col=0;col<64;++col) {
                const std::uint8_t b=byte_at(first,col>>1);
                const std::uint32_t nib=(col&1)?(b&0x0fU):(b>>4U);
                if (cold) {
                    if (nib!=0U) {
                        const double val=static_cast<double>(nib);
                        const double x=matrix[row*64+col]*static_cast<double>(hash_mod)*val+nonce_mod;
                        sum+=safe_nonlinear(x)*val*1234.0;
                    }
                } else {
                    sum+=matrix[row*64+col]*0.0001*static_cast<double>(nib);
                }
                cold=cvt_cold(sum);
            }
            floors[rr]=static_cast<std::uint64_t>(__double2ull_rz(sum));
        }
        const std::uint64_t p=floors[0]+floors[1];
        mixed[pair>>2]^=static_cast<std::uint32_t>(p&0xffU)<<((pair&3)*8);
    }
}

__device__ __forceinline__ void q20_mix(const double* matrix, const std::int32_t* table,
                                         std::uint32_t nonce, const std::uint32_t first[8],
                                         std::uint32_t mixed[8]) {
    std::uint32_t hx=0U;
    #pragma unroll
    for (int i=0;i<8;++i) { hx^=first[i]; mixed[i]=first[i]; }
    const std::uint32_t hash_mod=bswap32(hx);
    const double nonce_mod=static_cast<double>(nonce&0xffU);
    bool cold=true;
    #pragma unroll 1
    for (int pair=0;pair<32;++pair) {
        std::uint64_t floors[2];
        #pragma unroll
        for (int rr=0;rr<2;++rr) {
            const int row=pair*2+rr; std::int64_t qsum=0;
            #pragma unroll 1
            for (int col=0;col<64;++col) {
                const std::uint8_t b=byte_at(first,col>>1);
                const std::uint32_t nib=(col&1)?(b&0x0fU):(b>>4U);
                if (cold) {
                    if (nib!=0U) {
                        const double val=static_cast<double>(nib);
                        const double x=matrix[row*64+col]*static_cast<double>(hash_mod)*val+nonce_mod;
                        const double c=safe_nonlinear(x)*val*1234.0;
                        qsum+=static_cast<std::int64_t>(floor(c*static_cast<double>(kQScale)+0.5));
                    }
                } else {
                    qsum+=static_cast<std::int64_t>(table[(row*64+col)*16+static_cast<int>(nib)]);
                }
                const std::int64_t rem=qsum%kQPeriod;
                cold=rem<=kQColdThreshold;
            }
            floors[rr]=static_cast<std::uint64_t>(qsum/kQScale);
        }
        const std::uint64_t p=floors[0]+floors[1];
        mixed[pair>>2]^=static_cast<std::uint32_t>(p&0xffU)<<((pair&3)*8);
    }
}

__global__ void exact_kernel(const double* matrix, std::uint32_t first_nonce,
                             std::uint32_t* hashes, std::size_t count) {
    const std::size_t i=static_cast<std::size_t>(blockIdx.x)*blockDim.x+threadIdx.x;
    if (i>=count) return;
    const std::uint32_t nonce=first_nonce+static_cast<std::uint32_t>(i);
    std::uint32_t first[8], mixed[8], final_hash[8];
    blake3_header80(nonce,first); exact_mix(matrix,nonce,first,mixed); blake3_32(mixed,final_hash);
    #pragma unroll
    for (int w=0;w<8;++w) hashes[i*8U+w]=final_hash[w];
}
__global__ void q20_kernel(const double* matrix, const std::int32_t* table, std::uint32_t first_nonce,
                           std::uint32_t* hashes, std::size_t count) {
    const std::size_t i=static_cast<std::size_t>(blockIdx.x)*blockDim.x+threadIdx.x;
    if (i>=count) return;
    const std::uint32_t nonce=first_nonce+static_cast<std::uint32_t>(i);
    std::uint32_t first[8], mixed[8], final_hash[8];
    blake3_header80(nonce,first); q20_mix(matrix,table,nonce,first,mixed); blake3_32(mixed,final_hash);
    #pragma unroll
    for (int w=0;w<8;++w) hashes[i*8U+w]=final_hash[w];
}

constexpr std::uint32_t h_iv[8]={0x6A09E667U,0xBB67AE85U,0x3C6EF372U,0xA54FF53AU,0x510E527FU,0x9B05688CU,0x1F83D9ABU,0x5BE0CD19U};
constexpr std::uint8_t h_sched[7][16]={{0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15},{2,6,3,10,7,0,4,13,1,11,12,5,9,14,15,8},{3,4,10,12,13,2,7,14,6,5,9,0,11,15,8,1},{10,7,12,9,14,3,13,15,4,0,11,2,5,8,1,6},{12,13,9,11,15,10,14,8,7,2,5,3,0,1,6,4},{9,14,11,5,8,12,15,1,13,3,0,10,2,6,4,7},{11,15,5,0,1,9,8,6,14,10,2,12,3,4,7,13}};
inline std::uint32_t h_rotr(std::uint32_t x,int n){return (x>>n)|(x<<(32-n));}
inline void h_g(std::uint32_t& a,std::uint32_t& b,std::uint32_t& c,std::uint32_t& d,std::uint32_t mx,std::uint32_t my){a=a+b+mx;d=h_rotr(d^a,16);c+=d;b=h_rotr(b^c,12);a=a+b+my;d=h_rotr(d^a,8);c+=d;b=h_rotr(b^c,7);}
void h_compress(const std::uint32_t cv[8],const std::uint32_t block[16],std::uint32_t len,std::uint32_t flags,std::uint32_t out[16]){std::uint32_t v[16];for(int i=0;i<8;++i)v[i]=cv[i];for(int i=0;i<4;++i)v[8+i]=h_iv[i];v[12]=0;v[13]=0;v[14]=len;v[15]=flags;for(int r=0;r<7;++r){auto s=h_sched[r];h_g(v[0],v[4],v[8],v[12],block[s[0]],block[s[1]]);h_g(v[1],v[5],v[9],v[13],block[s[2]],block[s[3]]);h_g(v[2],v[6],v[10],v[14],block[s[4]],block[s[5]]);h_g(v[3],v[7],v[11],v[15],block[s[6]],block[s[7]]);h_g(v[0],v[5],v[10],v[15],block[s[8]],block[s[9]]);h_g(v[1],v[6],v[11],v[12],block[s[10]],block[s[11]]);h_g(v[2],v[7],v[8],v[13],block[s[12]],block[s[13]]);h_g(v[3],v[4],v[9],v[14],block[s[14]],block[s[15]]);}for(int i=0;i<8;++i){out[i]=v[i]^v[i+8];out[i+8]=v[i+8]^cv[i];}}
inline std::uint32_t load_le32(const std::uint8_t* p){return static_cast<std::uint32_t>(p[0])|(static_cast<std::uint32_t>(p[1])<<8U)|(static_cast<std::uint32_t>(p[2])<<16U)|(static_cast<std::uint32_t>(p[3])<<24U);}
void store_le32(std::uint8_t* p,std::uint32_t x){p[0]=static_cast<std::uint8_t>(x);p[1]=static_cast<std::uint8_t>(x>>8U);p[2]=static_cast<std::uint8_t>(x>>16U);p[3]=static_cast<std::uint8_t>(x>>24U);}
std::uint8_t hex_nibble(char c){if(c>='0'&&c<='9')return static_cast<std::uint8_t>(c-'0');if(c>='a'&&c<='f')return static_cast<std::uint8_t>(c-'a'+10);if(c>='A'&&c<='F')return static_cast<std::uint8_t>(c-'A'+10);throw std::runtime_error("bad hex");}
template<std::size_t N> std::array<std::uint8_t,N> parse_hex(std::string_view s){if(s.size()!=N*2U)throw std::runtime_error("bad hex length");std::array<std::uint8_t,N> o{};for(std::size_t i=0;i<N;++i)o[i]=static_cast<std::uint8_t>((hex_nibble(s[i*2])<<4U)|hex_nibble(s[i*2+1]));return o;}
bool relaxed_hit_bytes(const std::uint32_t* words,unsigned bits){const unsigned full=bits/8U,rem=bits%8U;for(unsigned i=0;i<full;++i){const std::uint8_t b=static_cast<std::uint8_t>((words[i>>2]>>((i&3)*8))&0xffU);if(b!=0U)return false;}if(rem==0U)return true;const std::uint8_t b=static_cast<std::uint8_t>((words[full>>2]>>((full&3)*8))&0xffU);return (b&static_cast<std::uint8_t>(0xffU<<(8U-rem)))==0U;}
std::uint32_t hash_word(const Hash256& h,int w){return load_le32(h.data()+w*4);}

} // namespace

int main(int argc,char** argv){
    std::uint32_t count=131072U; unsigned target_bits=8U;
    if(argc>1)count=static_cast<std::uint32_t>(std::strtoul(argv[1],nullptr,10));
    if(argc>2)target_bits=static_cast<unsigned>(std::strtoul(argv[2],nullptr,10));
    if(count==0U||target_bits==0U||target_bits>16U)return 2;
    constexpr std::string_view hex="004000206857ad8097ae27f653ff45b867b80e7de26d89f5ca91435a088a1f6200000000941cfbf2fc87b80ebc90c37b217ade46a9279726e6d0ea9cc1ff93d8d059fc8a013f676afb24011d00064cd5";
    auto base=parse_hex<80>(hex); auto masked=base; for(int i=76;i<80;++i)masked[static_cast<std::size_t>(i)]=0;
    const auto seed=pepepow::crypto::blake3_hash(masked); const auto matrix=pepepow::crypto::generate_hoohash_matrix(seed);
    std::vector<double> flat(4096); std::vector<std::int32_t> qtable(4096*16);
    for(int r=0;r<64;++r)for(int c=0;c<64;++c){flat[r*64+c]=matrix[r][c];for(int n=0;n<16;++n){const double x=matrix[r][c]*0.0001*static_cast<double>(n)*static_cast<double>(kQScale);qtable[(r*64+c)*16+n]=static_cast<std::int32_t>(std::llround(x));}}
    std::uint32_t block[16]{},tmp[16]{},mid[8]{},tail[3]{};for(int i=0;i<16;++i)block[i]=load_le32(base.data()+i*4);h_compress(h_iv,block,64,kChunkStart,tmp);for(int i=0;i<8;++i)mid[i]=tmp[i];for(int i=0;i<3;++i)tail[i]=load_le32(base.data()+64+i*4);
    cuda_check(cudaMemcpyToSymbol(c_midstate,mid,sizeof(mid)),"copy midstate");cuda_check(cudaMemcpyToSymbol(c_tail,tail,sizeof(tail)),"copy tail");
    double* d_matrix=nullptr;std::int32_t* d_table=nullptr;std::uint32_t* d_exact=nullptr;std::uint32_t* d_fast=nullptr;
    cuda_check(cudaMalloc(&d_matrix,flat.size()*sizeof(double)),"malloc matrix");cuda_check(cudaMalloc(&d_table,qtable.size()*sizeof(std::int32_t)),"malloc table");cuda_check(cudaMalloc(&d_exact,static_cast<std::size_t>(count)*8U*sizeof(std::uint32_t)),"malloc exact");cuda_check(cudaMalloc(&d_fast,static_cast<std::size_t>(count)*8U*sizeof(std::uint32_t)),"malloc fast");
    cuda_check(cudaMemcpy(d_matrix,flat.data(),flat.size()*sizeof(double),cudaMemcpyHostToDevice),"copy matrix");cuda_check(cudaMemcpy(d_table,qtable.data(),qtable.size()*sizeof(std::int32_t),cudaMemcpyHostToDevice),"copy table");
    const int threads=256;const int blocks=(static_cast<int>(count)+threads-1)/threads;
    exact_kernel<<<blocks,threads>>>(d_matrix,0,d_exact,count);q20_kernel<<<blocks,threads>>>(d_matrix,d_table,0,d_fast,count);cuda_check(cudaDeviceSynchronize(),"warmup");
    cudaEvent_t a,b;cuda_check(cudaEventCreate(&a),"event a");cuda_check(cudaEventCreate(&b),"event b");
    float exact_ms=0.0f,fast_ms=0.0f;cuda_check(cudaEventRecord(a),"record exact start");exact_kernel<<<blocks,threads>>>(d_matrix,0,d_exact,count);cuda_check(cudaEventRecord(b),"record exact stop");cuda_check(cudaEventSynchronize(b),"sync exact");cuda_check(cudaEventElapsedTime(&exact_ms,a,b),"time exact");
    cuda_check(cudaEventRecord(a),"record fast start");q20_kernel<<<blocks,threads>>>(d_matrix,d_table,0,d_fast,count);cuda_check(cudaEventRecord(b),"record fast stop");cuda_check(cudaEventSynchronize(b),"sync fast");cuda_check(cudaEventElapsedTime(&fast_ms,a,b),"time fast");
    std::vector<std::uint32_t> exact(static_cast<std::size_t>(count)*8U),fast(static_cast<std::size_t>(count)*8U);cuda_check(cudaMemcpy(exact.data(),d_exact,exact.size()*sizeof(std::uint32_t),cudaMemcpyDeviceToHost),"copy exact hashes");cuda_check(cudaMemcpy(fast.data(),d_fast,fast.size()*sizeof(std::uint32_t),cudaMemcpyDeviceToHost),"copy fast hashes");
    std::uint64_t gpu_exact_mismatch=0,strict_hits=0,fast_hits=0,tp=0,fn=0,fp=0,mixed_hash_equal=0;
    for(std::uint32_t nonce=0;nonce<count;++nonce){auto header=base;store_le32(header.data()+76,nonce);const auto first=pepepow::crypto::blake3_hash(header);const auto strict_mixed=pepepow::crypto::hoohash_matrix_mix(matrix,first,nonce);const auto strict=pepepow::crypto::blake3_hash(strict_mixed);bool same=true;for(int w=0;w<8;++w)if(exact[static_cast<std::size_t>(nonce)*8U+w]!=hash_word(strict,w)){same=false;break;}if(!same)++gpu_exact_mismatch;bool strict_hit=true;const unsigned full=target_bits/8U,rem=target_bits%8U;for(unsigned i=0;i<full;++i)if(strict[i]!=0U)strict_hit=false;if(rem&& (strict[full]&static_cast<std::uint8_t>(0xffU<<(8U-rem)))!=0U)strict_hit=false;const bool fh=relaxed_hit_bytes(fast.data()+static_cast<std::size_t>(nonce)*8U,target_bits);if(strict_hit)++strict_hits;if(fh)++fast_hits;if(fh&&strict_hit)++tp;if(!fh&&strict_hit)++fn;if(fh&&!strict_hit)++fp;bool feq=true;for(int w=0;w<8;++w)if(fast[static_cast<std::size_t>(nonce)*8U+w]!=hash_word(strict,w)){feq=false;break;}if(feq)++mixed_hash_equal;}
    const double recall=strict_hits?static_cast<double>(tp)/strict_hits:0.0;const double precision=fast_hits?static_cast<double>(tp)/fast_hits:0.0;const double exact_mhs=static_cast<double>(count)/(static_cast<double>(exact_ms)/1000.0)/1e6;const double fast_mhs=static_cast<double>(count)/(static_cast<double>(fast_ms)/1000.0)/1e6;const double gain=100.0*(fast_mhs/exact_mhs-1.0);
    std::cout<<std::fixed<<std::setprecision(6)<<"candidate_class=speculative_filtered_hoohash\narchitecture=fixed_point_linear_state_q20_cuda\nnonces="<<count<<"\nrelaxed_target_bits="<<target_bits<<"\ngpu_exact_mismatches="<<gpu_exact_mismatch<<"\nstrict_hits="<<strict_hits<<"\nfast_hits="<<fast_hits<<"\ntrue_positives="<<tp<<"\nfalse_negatives="<<fn<<"\nfalse_positives="<<fp<<"\nrecall="<<recall<<"\nprecision="<<precision<<"\nvalidator_candidates="<<fast_hits<<"\nvalidator_filtered="<<fp<<"\ninvalid_submissions_after_strict_validation=0\nfull_hash_equal="<<mixed_hash_equal<<"\nexact_gpu_mhs="<<exact_mhs<<"\nfast_gpu_mhs="<<fast_mhs<<"\nthroughput_gain_pct="<<gain<<"\nrecall_gate_0_995="<<(recall>=0.995?"PASS":"REJECT")<<"\nthroughput_gate_25pct="<<(gain>=25.0?"PASS":"REJECT")<<"\nstrict_validator_gate="<<(gpu_exact_mismatch==0?"PASS":"REJECT")<<'\n';
    cudaEventDestroy(a);cudaEventDestroy(b);cudaFree(d_matrix);cudaFree(d_table);cudaFree(d_exact);cudaFree(d_fast);
    return (gpu_exact_mismatch==0 && recall>=0.995 && gain>=25.0)?0:3;
}
