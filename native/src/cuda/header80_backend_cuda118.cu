#include "pepepow/cuda/header80_backend.hpp"
#include "pepepow/core/header_builder.hpp"
#include "pepepow/crypto/blake3.hpp"
#include "pepepow/crypto/hoohash_reference.hpp"

#include <cuda_runtime.h>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <span>
#include <stdexcept>
#include <string>
#include <vector>

namespace pepepow {
namespace {
constexpr std::size_t kHashSize = 32;
constexpr std::size_t kMatrixElements = 64 * 64;
constexpr double kPi = 3.14159265358979323846;
constexpr double kEpsilon = 1e-9;
constexpr double kTM = 0.000001;
constexpr std::uint32_t kChunkStart = 1U;
constexpr std::uint32_t kChunkEnd = 2U;
constexpr std::uint32_t kRoot = 8U;

constexpr std::array<std::uint32_t, 8> kHostIv{
    0x6A09E667U,0xBB67AE85U,0x3C6EF372U,0xA54FF53AU,
    0x510E527FU,0x9B05688CU,0x1F83D9ABU,0x5BE0CD19U};
constexpr std::uint8_t kHostSchedule[7][16] = {
    {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15},
    {2,6,3,10,7,0,4,13,1,11,12,5,9,14,15,8},
    {3,4,10,12,13,2,7,14,6,5,9,0,11,15,8,1},
    {10,7,12,9,14,3,13,15,4,0,11,2,5,8,1,6},
    {12,13,9,11,15,10,14,8,7,2,5,3,0,1,6,4},
    {9,14,11,5,8,12,15,1,13,3,0,10,2,6,4,7},
    {11,15,5,0,1,9,8,6,14,10,2,12,3,4,7,13}};

// The matrix is job-constant and all threads in a warp read the same cell at
// the same point in the sequential HooHash loop. Constant memory turns those
// accesses into broadcasts and removes 32 KiB of global-memory traffic state.
__device__ __constant__ double d_matrix[kMatrixElements];
__device__ __constant__ std::uint32_t d_midstate[8];
__device__ __constant__ std::uint32_t d_tail_words[3];
__device__ __constant__ std::uint8_t d_target[kHashSize];
__device__ __constant__ std::uint32_t kIv[8] = {
    0x6A09E667U,0xBB67AE85U,0x3C6EF372U,0xA54FF53AU,
    0x510E527FU,0x9B05688CU,0x1F83D9ABU,0x5BE0CD19U};
__device__ __constant__ std::uint8_t kSchedule[7][16] = {
    {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15},
    {2,6,3,10,7,0,4,13,1,11,12,5,9,14,15,8},
    {3,4,10,12,13,2,7,14,6,5,9,0,11,15,8,1},
    {10,7,12,9,14,3,13,15,4,0,11,2,5,8,1,6},
    {12,13,9,11,15,10,14,8,7,2,5,3,0,1,6,4},
    {9,14,11,5,8,12,15,1,13,3,0,10,2,6,4,7},
    {11,15,5,0,1,9,8,6,14,10,2,12,3,4,7,13}};

struct DeviceSearchResult {
    unsigned int found;
    std::uint32_t nonce;
    std::uint8_t hash[kHashSize];
};

void cuda_check(cudaError_t rc, const char* what) {
    if (rc != cudaSuccess) {
        throw std::runtime_error(std::string(what) + ": " + cudaGetErrorString(rc));
    }
}

constexpr std::uint32_t host_rotr32(std::uint32_t value, int bits) noexcept {
    return (value >> bits) | (value << (32 - bits));
}
void host_g(std::uint32_t& a,std::uint32_t& b,std::uint32_t& c,std::uint32_t& d,
            std::uint32_t mx,std::uint32_t my) noexcept {
    a=a+b+mx; d=host_rotr32(d^a,16); c+=d; b=host_rotr32(b^c,12);
    a=a+b+my; d=host_rotr32(d^a,8); c+=d; b=host_rotr32(b^c,7);
}
std::uint32_t host_load_le32(const std::uint8_t* p) noexcept {
    return static_cast<std::uint32_t>(p[0]) |
           (static_cast<std::uint32_t>(p[1]) << 8U) |
           (static_cast<std::uint32_t>(p[2]) << 16U) |
           (static_cast<std::uint32_t>(p[3]) << 24U);
}
void host_compress(const std::uint32_t cv[8],const std::uint32_t block[16],
                   std::uint32_t len,std::uint32_t flags,std::uint32_t out[16]) noexcept {
    std::uint32_t v[16];
    for(int i=0;i<8;++i)v[i]=cv[i];
    for(int i=0;i<4;++i)v[8+i]=kHostIv[static_cast<std::size_t>(i)];
    v[12]=0;v[13]=0;v[14]=len;v[15]=flags;
    for(int r=0;r<7;++r){
        const std::uint8_t* s=kHostSchedule[r];
        host_g(v[0],v[4],v[8],v[12],block[s[0]],block[s[1]]);
        host_g(v[1],v[5],v[9],v[13],block[s[2]],block[s[3]]);
        host_g(v[2],v[6],v[10],v[14],block[s[4]],block[s[5]]);
        host_g(v[3],v[7],v[11],v[15],block[s[6]],block[s[7]]);
        host_g(v[0],v[5],v[10],v[15],block[s[8]],block[s[9]]);
        host_g(v[1],v[6],v[11],v[12],block[s[10]],block[s[11]]);
        host_g(v[2],v[7],v[8],v[13],block[s[12]],block[s[13]]);
        host_g(v[3],v[4],v[9],v[14],block[s[14]],block[s[15]]);
    }
    for(int i=0;i<8;++i){out[i]=v[i]^v[i+8];out[i+8]=v[i+8]^cv[i];}
}
std::array<std::uint32_t,8> first_block_midstate(const Header80& header) noexcept {
    std::uint32_t block[16]{};
    std::uint32_t compressed[16]{};
    for(int i=0;i<16;++i)block[i]=host_load_le32(header.data()+i*4);
    host_compress(kHostIv.data(),block,64,kChunkStart,compressed);
    std::array<std::uint32_t,8> out{};
    std::copy_n(compressed,8,out.begin());
    return out;
}

__device__ __forceinline__ std::uint32_t rotr(std::uint32_t x,int n){return __funnelshift_r(x,x,n);}
__device__ __forceinline__ void g(std::uint32_t& a,std::uint32_t& b,std::uint32_t& c,std::uint32_t& d,std::uint32_t mx,std::uint32_t my){
    a=a+b+mx; d=rotr(d^a,16); c+=d; b=rotr(b^c,12);
    a=a+b+my; d=rotr(d^a,8); c+=d; b=rotr(b^c,7);
}
__device__ void compress(const std::uint32_t cv[8],const std::uint32_t block[16],std::uint32_t len,std::uint32_t flags,std::uint32_t out[16]){
    std::uint32_t v[16];
    #pragma unroll
    for(int i=0;i<8;++i)v[i]=cv[i];
    #pragma unroll
    for(int i=0;i<4;++i)v[8+i]=kIv[i];
    v[12]=0;v[13]=0;v[14]=len;v[15]=flags;
    #pragma unroll
    for(int r=0;r<7;++r){
        const std::uint8_t* s=kSchedule[r];
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
    for(int i=0;i<8;++i){out[i]=v[i]^v[i+8];out[i+8]=v[i+8]^cv[i];}
}
__device__ __forceinline__ std::uint32_t le32(const std::uint8_t* p){return std::uint32_t(p[0])|(std::uint32_t(p[1])<<8)|(std::uint32_t(p[2])<<16)|(std::uint32_t(p[3])<<24);}
__device__ __forceinline__ std::uint32_t be32(const std::uint8_t* p){return (std::uint32_t(p[0])<<24)|(std::uint32_t(p[1])<<16)|(std::uint32_t(p[2])<<8)|std::uint32_t(p[3]);}
__device__ __forceinline__ void put_le32(std::uint8_t* p,std::uint32_t v){p[0]=v;p[1]=v>>8;p[2]=v>>16;p[3]=v>>24;}
__device__ __forceinline__ std::uint32_t bswap32(std::uint32_t v){return __byte_perm(v,0,0x0123);}

// Only the last 16 bytes of the 80-byte header change per nonce. The first
// 64-byte BLAKE3 block is compressed on the CPU once per job and uploaded as a
// midstate, eliminating one complete BLAKE3 compression from every hash.
__device__ void blake80_from_midstate(std::uint32_t nonce,std::uint8_t out[32]){
    std::uint32_t cv[8],b[16],c[16];
    #pragma unroll
    for(int i=0;i<8;++i)cv[i]=d_midstate[i];
    #pragma unroll
    for(int i=0;i<16;++i)b[i]=0;
    b[0]=d_tail_words[0]; b[1]=d_tail_words[1]; b[2]=d_tail_words[2];
    b[3]=bswap32(nonce);
    compress(cv,b,16,kChunkEnd|kRoot,c);
    #pragma unroll
    for(int i=0;i<8;++i)put_le32(out+4*i,c[i]);
}
__device__ void blake32(const std::uint8_t in[32],std::uint8_t out[32]){
    std::uint32_t cv[8],b[16],c[16];
    #pragma unroll
    for(int i=0;i<8;++i)cv[i]=kIv[i];
    #pragma unroll
    for(int i=0;i<16;++i)b[i]=0;
    #pragma unroll
    for(int i=0;i<8;++i)b[i]=le32(in+4*i);
    compress(cv,b,32,kChunkStart|kChunkEnd|kRoot,c);
    #pragma unroll
    for(int i=0;i<8;++i)put_le32(out+4*i,c[i]);
}

__device__ __forceinline__ double complex_transform(double x){
    const double one_base=(x*kTM)/8.0;
    const double two_base=(x*kTM)/4.0;
    const double one=one_base-floor(one_base);
    const double two=two_base-floor(two_base);
    double y;
    if(two<0.25)y=x+(1.0+two);else if(two<0.50)y=x-(1.0+two);else if(two<0.75)y=x*(1.0+two);else y=x/(1.0+two);
    if(one<0.33){double s,c;sincos(y,&s,&c);return exp(s+c);}
    if(one<0.66){if(fabs(y-kPi/2.0)<kEpsilon||fabs(y-3.0*kPi/2.0)<kEpsilon)return 0.0;const double s=sin(y);return s*s;}
    return 1.0/sqrt(fabs(y)+1.0);
}
__device__ __forceinline__ double safe_complex(double input){
    // Consensus quirk: the reference intentionally does not recompute value in
    // this loop. Keep it byte-for-byte equivalent to the validated CPU oracle.
    double rounds=1.0;
    const double value=complex_transform(input);
    while(isnan(value)||isinf(value)){input*=0.1;if(input<=1e-13)return 0.0;rounds+=1.0;}
    return value*rounds;
}
__device__ __forceinline__ void accumulate_cell(double cell,double value,double hm,double nm,double& sum,double& sw){
    // A zero nibble contributes exactly +0.0 in either branch. Skipping the
    // expensive transcendental path is exact; sw is still updated from sum.
    if(value!=0.0){
        if(sw<=0.02){const double x=cell*hm*value+nm;sum+=safe_complex(x)*value*1234.0;}
        else sum+=cell*0.0001*value;
    }
    sw=sum/1024.0-floor(sum/1024.0);
}
__device__ double matrix_row(int row,const std::uint8_t first[32],double hm,double nm,double& sw){
    double sum=0.0;
    const int base=row*64;
    #pragma unroll 1
    for(int byte_index=0;byte_index<32;++byte_index){
        const std::uint8_t packed=first[byte_index];
        const int col=byte_index*2;
        accumulate_cell(d_matrix[base+col],static_cast<double>(packed>>4U),hm,nm,sum,sw);
        accumulate_cell(d_matrix[base+col+1],static_cast<double>(packed&0x0fU),hm,nm,sum,sw);
    }
    return sum;
}

template<bool Capture>
__device__ void hash_one(std::uint32_t nonce,std::uint8_t* final,std::uint8_t* cap1,std::uint8_t* cap2){
    std::uint8_t first[32],mixed[32];
    blake80_from_midstate(nonce,first);

    std::uint32_t hash_mod=0;
    #pragma unroll
    for(int i=0;i<8;++i)hash_mod^=be32(first+4*i);
    const double hm=static_cast<double>(hash_mod);
    const std::uint32_t mix_nonce=bswap32(nonce);
    const double nm=static_cast<double>(mix_nonce&0xffU);
    double sw=0.0;

    // Produce each output byte as soon as its two rows are complete. This keeps
    // only two FP64 row accumulators live instead of a 64-double local array.
    #pragma unroll 1
    for(int pair=0;pair<32;++pair){
        const double even=matrix_row(pair*2,first,hm,nm,sw);
        const double odd=matrix_row(pair*2+1,first,hm,nm,sw);
        const std::uint64_t p=static_cast<std::uint64_t>(even)+static_cast<std::uint64_t>(odd);
        mixed[pair]=first[pair]^static_cast<std::uint8_t>(p&0xffU);
    }
    blake32(mixed,final);
    if(Capture){
        #pragma unroll
        for(int i=0;i<32;++i){cap1[i]=first[i];cap2[i]=mixed[i];}
    }
}

__device__ __forceinline__ bool hash_meets_target_be(const std::uint8_t hash[32]){
    #pragma unroll
    for(int i=0;i<32;++i){if(hash[i]<d_target[i])return true;if(hash[i]>d_target[i])return false;}
    return true;
}
__global__ void search_kernel(std::uint32_t first,DeviceSearchResult* result,std::size_t count){
    const std::size_t idx=std::size_t(blockIdx.x)*blockDim.x+threadIdx.x;
    if(idx>=count)return;
    const std::uint32_t nonce=first+static_cast<std::uint32_t>(idx);
    std::uint8_t hash[32];hash_one<false>(nonce,hash,nullptr,nullptr);
    if(!hash_meets_target_be(hash))return;
    if(atomicCAS(&result->found,0U,1U)==0U){result->nonce=nonce;
        #pragma unroll
        for(int i=0;i<32;++i)result->hash[i]=hash[i];}
}
__global__ void diag_kernel(std::uint32_t nonce,std::uint8_t* first,std::uint8_t* mixed,std::uint8_t* final){
    if(blockIdx.x||threadIdx.x)return;hash_one<true>(nonce,final,first,mixed);
}

void prepare_job(int device,const MiningJob& job){
    MiningJob base_job=job;base_job.nonce=0U;
    const Header80 header=build_header80(base_job);
    Header80 masked=header;
    std::fill(masked.begin()+76,masked.end(),0U);
    const crypto::Hash256 matrix_seed=crypto::blake3_hash(std::span<const std::uint8_t>(masked.data(),masked.size()));
    const auto midstate=first_block_midstate(header);
    const std::array<std::uint32_t,3> tail_words{
        host_load_le32(header.data()+64),host_load_le32(header.data()+68),host_load_le32(header.data()+72)};

    cuda_check(cudaSetDevice(device),"cudaSetDevice");

    // One worker thread owns one CUDA device. Cache matrix uploads across scan
    // chunks; a new matrix is copied only when the job seed changes.
    static thread_local bool matrix_cached=false;
    static thread_local int matrix_device=-1;
    static thread_local crypto::Hash256 cached_seed{};
    if(!matrix_cached||matrix_device!=device||cached_seed!=matrix_seed){
        const crypto::HoohashMatrix matrix=crypto::generate_hoohash_matrix(matrix_seed);
        cuda_check(cudaMemcpyToSymbol(d_matrix,matrix.data()->data(),kMatrixElements*sizeof(double),0,cudaMemcpyHostToDevice),"copy HooHash matrix");
        cached_seed=matrix_seed;matrix_device=device;matrix_cached=true;
    }
    cuda_check(cudaMemcpyToSymbol(d_midstate,midstate.data(),sizeof(midstate),0,cudaMemcpyHostToDevice),"copy BLAKE3 midstate");
    cuda_check(cudaMemcpyToSymbol(d_tail_words,tail_words.data(),sizeof(tail_words),0,cudaMemcpyHostToDevice),"copy header tail");
}
} // namespace

Header80CudaBackend::Header80CudaBackend(int device_index):device_index_(device_index){}
std::string_view Header80CudaBackend::name() const noexcept{return "cuda-hoohash-hotloop-cuda118";}
std::vector<DeviceInfo> Header80CudaBackend::enumerate_devices() const{
    int n=0;cuda_check(cudaGetDeviceCount(&n),"cudaGetDeviceCount");std::vector<DeviceInfo> out;out.reserve(static_cast<std::size_t>(n));
    for(int i=0;i<n;++i){cudaDeviceProp p{};cuda_check(cudaGetDeviceProperties(&p,i),"cudaGetDeviceProperties");out.push_back(DeviceInfo{i,p.name,p.major,p.minor,p.totalGlobalMem});}
    return out;
}
Header80CudaDiagnostics Header80CudaBackend::diagnose(const MiningJob& job,std::uint32_t nonce){
    prepare_job(device_index_,job);
    std::uint8_t *d1=nullptr,*d2=nullptr,*df=nullptr;
    try{
        cuda_check(cudaMalloc(reinterpret_cast<void**>(&d1),32),"cudaMalloc diag first");
        cuda_check(cudaMalloc(reinterpret_cast<void**>(&d2),32),"cudaMalloc diag mixed");
        cuda_check(cudaMalloc(reinterpret_cast<void**>(&df),32),"cudaMalloc diag final");
        diag_kernel<<<1,1>>>(nonce,d1,d2,df);cuda_check(cudaGetLastError(),"diag launch");cuda_check(cudaDeviceSynchronize(),"diag sync");
        Header80CudaDiagnostics r{};
        cuda_check(cudaMemcpy(r.first_pass.data(),d1,32,cudaMemcpyDeviceToHost),"copy diag first");
        cuda_check(cudaMemcpy(r.mixed.data(),d2,32,cudaMemcpyDeviceToHost),"copy diag mixed");
        cuda_check(cudaMemcpy(r.final_hash.data(),df,32,cudaMemcpyDeviceToHost),"copy diag final");
        cudaFree(df);cudaFree(d2);cudaFree(d1);return r;
    }catch(...){if(df)cudaFree(df);if(d2)cudaFree(d2);if(d1)cudaFree(d1);throw;}
}
std::optional<ShareCandidate> Header80CudaBackend::search(const MiningJob& job,SearchRange range,const Hash256& target){
    if(range.count==0||range.begin>std::numeric_limits<std::uint32_t>::max())return std::nullopt;
    const std::uint64_t avail=0x100000000ULL-range.begin;
    const std::size_t count=static_cast<std::size_t>(std::min(range.count,avail));
    if(!count)return std::nullopt;

    prepare_job(device_index_,job);
    DeviceSearchResult* dresult=nullptr;
    try{
        cuda_check(cudaMemcpyToSymbol(d_target,target.data(),target.size()),"copy target");
        cuda_check(cudaMalloc(reinterpret_cast<void**>(&dresult),sizeof(DeviceSearchResult)),"cudaMalloc search result");
        cuda_check(cudaMemset(dresult,0,sizeof(DeviceSearchResult)),"clear search result");
        // 64 threads/block is the consensus reference geometry for this FP64-heavy
        // kernel and is safe on Volta sm_70 as well as newer supported devices.
        constexpr unsigned threads=64;
        const unsigned blocks=static_cast<unsigned>((count+threads-1)/threads);
        search_kernel<<<blocks,threads>>>(static_cast<std::uint32_t>(range.begin),dresult,count);
        cuda_check(cudaGetLastError(),"search launch");cuda_check(cudaDeviceSynchronize(),"search sync");
        DeviceSearchResult result{};cuda_check(cudaMemcpy(&result,dresult,sizeof(result),cudaMemcpyDeviceToHost),"copy search result");
        cudaFree(dresult);dresult=nullptr;
        if(!result.found)return std::nullopt;
        Hash256 hash{};std::copy_n(result.hash,32,hash.begin());
        return ShareCandidate{job.job_id,result.nonce,hash};
    }catch(...){if(dresult)cudaFree(dresult);throw;}
}
} // namespace pepepow
