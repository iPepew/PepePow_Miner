#include "pepepow/cuda/header80_backend.hpp"
#include "pepepow/core/header_builder.hpp"

#include <cuda_runtime.h>
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <stdexcept>
#include <string>
#include <vector>

namespace pepepow {
namespace {
constexpr std::size_t kHeaderSize = 80;
constexpr std::size_t kHeaderPrefixSize = 76;
constexpr double kPi = 3.14159265358979323846;
constexpr double kEpsilon = 1e-9;
constexpr double kTM = 0.000001;
constexpr std::uint32_t kChunkStart = 1U;
constexpr std::uint32_t kChunkEnd = 2U;
constexpr std::uint32_t kRoot = 8U;

struct DeviceSearchResult {
    unsigned int found;
    std::uint32_t nonce;
    std::uint8_t hash[32];
};

// Keep the HooHash matrix in device global memory. The reference PEPEPOW CUDA
// implementation uses the same layout: mat[i][j] is warp-uniform and therefore
// benefits from broadcast/L2 behavior without constant-memory serialization.
__device__ double d_matrix[64][64];
__device__ __constant__ std::uint8_t d_target[32];
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

void cuda_check(cudaError_t rc, const char* what) {
    if (rc != cudaSuccess) throw std::runtime_error(std::string(what)+": "+cudaGetErrorString(rc));
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
__device__ __forceinline__ std::uint64_t le64(const std::uint8_t* p){std::uint64_t v=0;for(int i=0;i<8;++i)v|=std::uint64_t(p[i])<<(8*i);return v;}
__device__ __forceinline__ void put_le32(std::uint8_t* p,std::uint32_t v){p[0]=v;p[1]=v>>8;p[2]=v>>16;p[3]=v>>24;}
__device__ __forceinline__ void put_be32(std::uint8_t* p,std::uint32_t v){p[0]=v>>24;p[1]=v>>16;p[2]=v>>8;p[3]=v;}

__device__ void blake80(const std::uint8_t in[80],std::uint8_t out[32]){
    std::uint32_t cv[8],b[16],c[16];
    #pragma unroll
    for(int i=0;i<8;++i)cv[i]=kIv[i];
    #pragma unroll
    for(int i=0;i<16;++i)b[i]=le32(in+4*i);
    compress(cv,b,64,kChunkStart,c);
    #pragma unroll
    for(int i=0;i<8;++i)cv[i]=c[i];
    #pragma unroll
    for(int i=0;i<16;++i)b[i]=0;
    #pragma unroll
    for(int i=0;i<4;++i)b[i]=le32(in+64+4*i);
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

struct Xoshiro{std::uint64_t s0,s1,s2,s3;};
__device__ __forceinline__ std::uint64_t rol64(std::uint64_t x,int k){return (x<<k)|(x>>(64-k));}
__device__ __forceinline__ std::uint64_t xnext(Xoshiro& s){
    const std::uint64_t result=rol64(s.s0+s.s3,23)+s.s0;
    const std::uint64_t t=s.s1<<17;
    s.s2^=s.s0;s.s3^=s.s1;s.s1^=s.s2;s.s0^=s.s3;s.s2^=t;s.s3=rol64(s.s3,45);return result;
}
__global__ void matrix_kernel(const std::uint8_t* header){
    if(blockIdx.x||threadIdx.x)return;
    std::uint8_t masked[80];
    #pragma unroll
    for(int i=0;i<80;++i)masked[i]=header[i];
    masked[76]=masked[77]=masked[78]=masked[79]=0;
    std::uint8_t seed[32];blake80(masked,seed);
    Xoshiro s{le64(seed),le64(seed+8),le64(seed+16),le64(seed+24)};
    for(int i=0;i<64;++i)for(int j=0;j<64;++j){
        const std::uint32_t low=static_cast<std::uint32_t>(xnext(s));
        d_matrix[i][j]=static_cast<double>(low)/static_cast<double>(0xffffffffU)*1000000.0;
    }
}

__device__ __forceinline__ double complex_transform(double x){
    const double one=(x*kTM)/8.0-floor((x*kTM)/8.0);
    const double two=(x*kTM)/4.0-floor((x*kTM)/4.0);
    double y;
    if(two<0.25)y=x+(1.0+two);else if(two<0.50)y=x-(1.0+two);else if(two<0.75)y=x*(1.0+two);else y=x/(1.0+two);
    if(one<0.33){double s,c;sincos(y,&s,&c);return exp(s+c);}
    if(one<0.66){if(fabs(y-kPi/2.0)<kEpsilon||fabs(y-3.0*kPi/2.0)<kEpsilon)return 0.0;const double s=sin(y);return s*s;}
    return 1.0/sqrt(fabs(y)+1.0);
}
__device__ __forceinline__ double safe_complex(double input){
    double rounds=1.0;const double value=complex_transform(input);
    while(isnan(value)||isinf(value)){input*=0.1;if(input<=1e-13)return 0.0;rounds+=1.0;}return value*rounds;
}
__device__ void mix(const std::uint8_t first[32],std::uint8_t out[32],std::uint32_t nonce){
    std::uint8_t vec[64];double prod[64]={0.0};std::uint32_t h[8];
    #pragma unroll
    for(int i=0;i<8;++i)h[i]=be32(first+4*i);
    const double hm=static_cast<double>(h[0]^h[1]^h[2]^h[3]^h[4]^h[5]^h[6]^h[7]);
    const double nm=static_cast<double>(nonce&0xffU);
    #pragma unroll
    for(int i=0;i<32;++i){vec[2*i]=first[i]>>4;vec[2*i+1]=first[i]&0xf;}
    double sw=0.0;
    for(int i=0;i<64;++i)for(int j=0;j<64;++j){
        if(sw<=0.02){const double x=d_matrix[i][j]*hm*static_cast<double>(vec[j])+nm;prod[i]+=safe_complex(x)*static_cast<double>(vec[j])*1234.0;}
        else prod[i]+=d_matrix[i][j]*0.0001*static_cast<double>(vec[j]);
        sw=prod[i]/1024.0-floor(prod[i]/1024.0);
    }
    #pragma unroll
    for(int i=0;i<32;++i){const std::uint64_t p=static_cast<std::uint64_t>(prod[2*i])+static_cast<std::uint64_t>(prod[2*i+1]);out[i]=first[i]^static_cast<std::uint8_t>(p&0xffU);}
}

template<bool Capture>
__device__ void hash_one(const std::uint8_t* base,std::uint32_t nonce,std::uint8_t* final,std::uint8_t* cap1,std::uint8_t* cap2){
    std::uint8_t header[kHeaderSize];
    #pragma unroll
    for(int i=0;i<80;++i)header[i]=base[i];
    put_be32(header+76,nonce);
    std::uint8_t first[32],mixed[32];blake80(header,first);mix(first,mixed,le32(header+76));blake32(mixed,final);
    if(Capture){
        #pragma unroll
        for(int i=0;i<32;++i){cap1[i]=first[i];cap2[i]=mixed[i];}
    }
}

__device__ __forceinline__ bool hash_meets_target_be_device(const std::uint8_t hash[32]){
    #pragma unroll
    for(int i=0;i<32;++i){
        if(hash[i]<d_target[i])return true;
        if(hash[i]>d_target[i])return false;
    }
    return true;
}

__global__ void search_kernel(const std::uint8_t* base,std::uint32_t first,DeviceSearchResult* result,std::size_t count){
    const std::size_t idx=std::size_t(blockIdx.x)*blockDim.x+threadIdx.x;
    if(idx>=count)return;
    const std::uint32_t nonce=first+static_cast<std::uint32_t>(idx);
    std::uint8_t hash[32];
    hash_one<false>(base,nonce,hash,nullptr,nullptr);
    if(!hash_meets_target_be_device(hash))return;
    if(atomicCAS(&result->found,0U,1U)==0U){
        result->nonce=nonce;
        #pragma unroll
        for(int i=0;i<32;++i)result->hash[i]=hash[i];
    }
}
__global__ void diag_kernel(const std::uint8_t* base,std::uint32_t nonce,std::uint8_t* first,std::uint8_t* mixed,std::uint8_t* final){if(blockIdx.x||threadIdx.x)return;hash_one<true>(base,nonce,final,first,mixed);}

Header80 make_header(const MiningJob& job,std::uint32_t nonce){MiningJob j=job;j.nonce=nonce;return build_header80(j);}

bool same_job_prefix(const Header80& left,const Header80& right){
    return std::equal(left.begin(),left.begin()+static_cast<std::ptrdiff_t>(kHeaderPrefixSize),right.begin());
}
} // namespace

Header80CudaBackend::Header80CudaBackend(int device_index):device_index_(device_index){}

Header80CudaBackend::~Header80CudaBackend(){
    release_device_state();
}

void Header80CudaBackend::release_device_state() noexcept{
    if(device_header_==nullptr && device_result_==nullptr)return;
    if(cudaSetDevice(device_index_)==cudaSuccess){
        if(device_result_!=nullptr)cudaFree(device_result_);
        if(device_header_!=nullptr)cudaFree(device_header_);
    }
    device_result_=nullptr;
    device_header_=nullptr;
    header_ready_=false;
    target_ready_=false;
}

void Header80CudaBackend::ensure_device_state(){
    cuda_check(cudaSetDevice(device_index_),"cudaSetDevice");
    if(device_header_==nullptr){
        std::uint8_t* header=nullptr;
        cuda_check(cudaMalloc(reinterpret_cast<void**>(&header),kHeaderSize),"cudaMalloc persistent header");
        device_header_=header;
    }
    if(device_result_==nullptr){
        DeviceSearchResult* result=nullptr;
        cuda_check(cudaMalloc(reinterpret_cast<void**>(&result),sizeof(DeviceSearchResult)),"cudaMalloc persistent search result");
        device_result_=result;
    }
}

void Header80CudaBackend::prepare_job(const Header80& header){
    ensure_device_state();
    if(header_ready_ && same_job_prefix(header,cached_header_))return;

    auto* device_header=static_cast<std::uint8_t*>(device_header_);
    cuda_check(cudaMemcpy(device_header,header.data(),kHeaderSize,cudaMemcpyHostToDevice),"cudaMemcpy persistent header");
    matrix_kernel<<<1,1>>>(device_header);
    cuda_check(cudaGetLastError(),"matrix_kernel launch");

    // matrix_kernel and the subsequent search kernel run in the same default
    // stream, so no host-side device synchronization is needed here.
    cached_header_=header;
    header_ready_=true;
}

void Header80CudaBackend::prepare_target(const Hash256& target){
    ensure_device_state();
    if(target_ready_ && target==cached_target_)return;
    cuda_check(cudaMemcpyToSymbol(d_target,target.data(),target.size()),"copy target");
    cached_target_=target;
    target_ready_=true;
}

std::string_view Header80CudaBackend::name() const noexcept{return "cuda-header80-persistent-global-cuda118";}

std::vector<DeviceInfo> Header80CudaBackend::enumerate_devices() const{
    int n=0;cuda_check(cudaGetDeviceCount(&n),"cudaGetDeviceCount");std::vector<DeviceInfo> out;out.reserve(static_cast<std::size_t>(n));
    for(int i=0;i<n;++i){cudaDeviceProp p{};cuda_check(cudaGetDeviceProperties(&p,i),"cudaGetDeviceProperties");out.push_back(DeviceInfo{i,p.name,p.major,p.minor,p.totalGlobalMem});}return out;
}

Header80CudaDiagnostics Header80CudaBackend::diagnose(const MiningJob& job,std::uint32_t nonce){
    const Header80 header=make_header(job,nonce);
    prepare_job(header);
    auto* device_header=static_cast<std::uint8_t*>(device_header_);
    std::uint8_t *d1=nullptr,*d2=nullptr,*df=nullptr;
    try{
        cuda_check(cudaMalloc(reinterpret_cast<void**>(&d1),32),"cudaMalloc diag first");
        cuda_check(cudaMalloc(reinterpret_cast<void**>(&d2),32),"cudaMalloc diag mixed");
        cuda_check(cudaMalloc(reinterpret_cast<void**>(&df),32),"cudaMalloc diag final");
        diag_kernel<<<1,1>>>(device_header,nonce,d1,d2,df);
        cuda_check(cudaGetLastError(),"diag launch");
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

    const Header80 header=make_header(job,static_cast<std::uint32_t>(range.begin));
    prepare_job(header);
    prepare_target(target);

    auto* device_header=static_cast<std::uint8_t*>(device_header_);
    auto* device_result=static_cast<DeviceSearchResult*>(device_result_);
    cuda_check(cudaMemset(device_result,0,sizeof(DeviceSearchResult)),"clear persistent search result");

    constexpr unsigned threads=64;
    const unsigned blocks=static_cast<unsigned>((count+threads-1)/threads);
    search_kernel<<<blocks,threads>>>(device_header,static_cast<std::uint32_t>(range.begin),device_result,count);
    cuda_check(cudaGetLastError(),"search launch");

    // A blocking D2H copy on the default stream waits for the search kernel,
    // making the former explicit cudaDeviceSynchronize() redundant.
    DeviceSearchResult result{};
    cuda_check(cudaMemcpy(&result,device_result,sizeof(result),cudaMemcpyDeviceToHost),"copy search result");
    if(!result.found)return std::nullopt;

    Hash256 hash{};
    std::copy_n(result.hash,32,hash.begin());
    return ShareCandidate{job.job_id,result.nonce,hash};
}
} // namespace pepepow
