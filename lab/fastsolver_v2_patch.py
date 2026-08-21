#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: fastsolver_v2_patch.py <generated-cu>')

p = Path(sys.argv[1])
s = p.read_text()

def replace_once(old: str, new: str, label: str) -> None:
    global s
    if old not in s:
        raise SystemExit(f'{label} marker missing')
    s = s.replace(old, new, 1)

replace_once(
    '#include "pepepow/crypto/hoohash_reference.hpp"\n',
    '#include "pepepow/crypto/hoohash_reference.hpp"\n#include "pepepow/crypto/pow.hpp"\n#include "pepepow/mining/target.hpp"\n',
    'validation includes')

replace_once(
    '__device__ __constant__ double d_matrix[64][64];\n',
    '__device__ __constant__ double d_matrix[64][64];\n'
    'constexpr unsigned kFastPhaseLutIntervals = 98304U;\n'
    '__device__ double d_exp_sincossum_lut[kFastPhaseLutIntervals + 1U];\n',
    'LUT declaration')

complex_marker = '__device__ __forceinline__ double complex_transform(double x){\n'
fast_code = r'''// FastSolver V2: the strict reference remains available for diagnostics/KAT.
// The mining path removes large-argument trig reduction from the two expensive
// nonlinear branches. 1/(2*pi) is stored as a 192-bit fixed-point integer:
//   floor(2^192 / (2*pi)) =
//   0x28be60db9391054a7f09d5f47d4d377036d8a5664f10e410.
// A 53-bit FP64 mantissa multiplied by those three limbs gives enough phase
// precision for the full HooHash input range without calling fmod/remainder.
__global__ void init_exp_sincossum_lut_kernel(){
    const unsigned i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i>kFastPhaseLutIntervals)return;
    const double phase=(2.0*kPi*static_cast<double>(i))/static_cast<double>(kFastPhaseLutIntervals);
    double sn,cs;
    sincos(phase,&sn,&cs);
    d_exp_sincossum_lut[i]=exp(sn+cs);
}

__device__ __forceinline__ void mul53x192(
    unsigned long long m,
    unsigned long long& p0,unsigned long long& p1,
    unsigned long long& p2,unsigned long long& p3){
    constexpr unsigned long long c0=0x36d8a5664f10e410ULL;
    constexpr unsigned long long c1=0x7f09d5f47d4d3770ULL;
    constexpr unsigned long long c2=0x28be60db9391054aULL;
    const unsigned long long l0=m*c0,h0=__umul64hi(m,c0);
    const unsigned long long l1=m*c1,h1=__umul64hi(m,c1);
    const unsigned long long l2=m*c2,h2=__umul64hi(m,c2);
    p0=l0;
    p1=h0+l1;
    const unsigned long long carry1=(p1<h0)?1ULL:0ULL;
    const unsigned long long t=h1+l2;
    const unsigned long long carry2a=(t<h1)?1ULL:0ULL;
    p2=t+carry1;
    const unsigned long long carry2b=(p2<t)?1ULL:0ULL;
    p3=h2+carry2a+carry2b;
}

__device__ __noinline__ bool fast_phase_frac64(double y,unsigned long long* out){
    const unsigned long long bits=static_cast<unsigned long long>(__double_as_longlong(fabs(y)));
    const unsigned eb=static_cast<unsigned>((bits>>52)&0x7ffULL);
    if(eb==0U||eb==0x7ffU)return false;
    const int exponent=static_cast<int>(eb)-1023;
    // q = mantissa*C / 2^(244-exponent). We need the 64 bits directly
    // below that binary point. HooHash's large nonlinear arguments live well
    // inside this range; tiny/outlier values fall back to the strict function.
    const int shift_to_point=244-exponent;
    if(shift_to_point<64||shift_to_point>256)return false;
    const unsigned long long mantissa=(bits&0x000fffffffffffffULL)|0x0010000000000000ULL;
    unsigned long long p0,p1,p2,p3;
    mul53x192(mantissa,p0,p1,p2,p3);
    const int bitpos=shift_to_point-64;
    const int limb=bitpos>>6;
    const int sh=bitpos&63;
    unsigned long long lo=0ULL,hi=0ULL;
    if(limb==0){lo=p0;hi=p1;}
    else if(limb==1){lo=p1;hi=p2;}
    else if(limb==2){lo=p2;hi=p3;}
    else {lo=p3;hi=0ULL;}
    unsigned long long frac=(sh==0)?lo:(lo>>sh)|(hi<<(64-sh));
    if(y<0.0&&frac!=0ULL)frac=0ULL-frac;
    *out=frac;
    return true;
}

__device__ __noinline__ double fast_exp_sincossum(double y){
    unsigned long long frac;
    if(!fast_phase_frac64(y,&frac)){
        double sn,cs;sincos(y,&sn,&cs);return exp(sn+cs);
    }
    constexpr unsigned long long n=static_cast<unsigned long long>(kFastPhaseLutIntervals);
    unsigned idx=static_cast<unsigned>(__umul64hi(frac,n));
    if(idx>=kFastPhaseLutIntervals)idx=kFastPhaseLutIntervals-1U;
    const unsigned long long cell=frac*n;
    const double t=__ull2double_rn(cell)*0x1p-64;
    const double a=__ldg(&d_exp_sincossum_lut[idx]);
    const double b=__ldg(&d_exp_sincossum_lut[idx+1U]);
    return a+(b-a)*t;
}

__device__ __noinline__ double fast_sin2(double y){
    unsigned long long frac;
    if(!fast_phase_frac64(y,&frac)){
        const double sn=sin(y);return sn*sn;
    }
    const double u=__ull2double_rn(frac)*0x1p-64;
    // The reduced argument is in [0,2*pi], avoiding CUDA's expensive
    // large-argument trig reduction slow path.
    const double sn=sin((2.0*kPi)*u);
    return sn*sn;
}

__device__ __forceinline__ double complex_transform_fast(double x){
    const double scaled=x*kTM;
    const double q=scaled*0.125;
    const double one=q-floor(q);
    double two=one+one;
    if(two>=1.0)two-=1.0;
    double y;
    if(two<0.25)y=x+(1.0+two);else if(two<0.50)y=x-(1.0+two);else if(two<0.75)y=x*(1.0+two);else y=x/(1.0+two);
    if(one<0.33)return fast_exp_sincossum(y);
    if(one<0.66){
        if(fabs(y-kPi/2.0)<kEpsilon||fabs(y-3.0*kPi/2.0)<kEpsilon)return 0.0;
        return fast_sin2(y);
    }
    return 1.0/sqrt(fabs(y)+1.0);
}

'''
replace_once(complex_marker, fast_code + complex_marker, 'complex transform insertion')

accum_marker = '''__device__ __forceinline__ void accumulate_row(
    int row,const std::uint8_t first[32],double hm,double nm,double& sw,double& product){
    #pragma unroll 1
    for(int j=0;j<64;++j){
        const double v=static_cast<double>(nibble(first,j));
        if(sw<=0.02){
            const double x=d_matrix[row][j]*hm*v+nm;
            product+=safe_complex(x)*v*1234.0;
        }else{
            product+=d_matrix[row][j]*0.0001*v;
        }
        sw=product/1024.0-floor(product/1024.0);
    }
}
'''
fast_accum = accum_marker + r'''
__device__ __forceinline__ void accumulate_row_fast(
    int row,const std::uint8_t first[32],double hm,double nm,double& sw,double& product){
    #pragma unroll 1
    for(int j=0;j<64;++j){
        const double v=static_cast<double>(nibble(first,j));
        if(sw<=0.02){
            const double x=d_matrix[row][j]*hm*v+nm;
            product+=complex_transform_fast(x)*v*1234.0;
        }else{
            product+=d_matrix[row][j]*0.0001*v;
        }
        sw=product/1024.0-floor(product/1024.0);
    }
}

__device__ void mix_streamed_fast(const std::uint8_t first[32],std::uint8_t out[32],std::uint32_t nonce_wire){
    std::uint32_t hash_mod=0U;
    #pragma unroll
    for(int i=0;i<8;++i)hash_mod^=be32(first+4*i);
    const double hm=static_cast<double>(hash_mod);
    const double nm=static_cast<double>(nonce_wire&0xffU);
    double sw=0.0;
    #pragma unroll 1
    for(int pair=0;pair<32;++pair){
        double p0=0.0,p1=0.0;
        accumulate_row_fast(pair*2,first,hm,nm,sw,p0);
        accumulate_row_fast(pair*2+1,first,hm,nm,sw,p1);
        const std::uint64_t p=static_cast<std::uint64_t>(p0)+static_cast<std::uint64_t>(p1);
        out[pair]=first[pair]^static_cast<std::uint8_t>(p&0xffU);
    }
}
'''
replace_once(accum_marker, fast_accum, 'fast accumulator')

hash_marker = '''template<bool Capture>
__device__ void hash_one(const std::uint8_t* base,std::uint32_t nonce,std::uint8_t* final,std::uint8_t* cap1,std::uint8_t* cap2){
    std::uint8_t first[32],mixed[32];
    blake80_tail(base,nonce,first);
    mix_streamed(first,mixed,bswap32(nonce));
    blake32(mixed,final);
    if(Capture){
        #pragma unroll
        for(int i=0;i<32;++i){cap1[i]=first[i];cap2[i]=mixed[i];}
    }
}
'''
fast_hash = hash_marker + r'''
__device__ void hash_one_fast(const std::uint8_t* base,std::uint32_t nonce,std::uint8_t* final){
    std::uint8_t first[32],mixed[32];
    blake80_tail(base,nonce,first);
    mix_streamed_fast(first,mixed,bswap32(nonce));
    blake32(mixed,final);
}
'''
replace_once(hash_marker, fast_hash, 'fast hash')

replace_once(
    '    hash_one<false>(base,nonce,hash,nullptr,nullptr);\n',
    '    hash_one_fast(base,nonce,hash);\n',
    'search fast path')

ensure_marker = '''void Header80CudaBackend::ensure_device_state(){
    cuda_check(cudaSetDevice(device_index_),"cudaSetDevice");
'''
ensure_repl = ensure_marker + r'''    static bool lut_ready[32]={false};
    if(device_index_>=0&&device_index_<32&&!lut_ready[device_index_]){
        constexpr unsigned t=256U;
        constexpr unsigned b=(kFastPhaseLutIntervals+1U+t-1U)/t;
        init_exp_sincossum_lut_kernel<<<b,t>>>();
        cuda_check(cudaGetLastError(),"init FastSolver V2 exp(sin+cos) LUT");
        cuda_check(cudaDeviceSynchronize(),"sync FastSolver V2 exp(sin+cos) LUT");
        lut_ready[device_index_]=true;
    }
'''
replace_once(ensure_marker, ensure_repl, 'LUT init')

result_marker = '''    Hash256 hash{};
    std::copy_n(result.hash,32,hash.begin());
    return ShareCandidate{job.job_id,result.nonce,hash};
'''
result_repl = r'''    // Never submit the approximate GPU result directly. Recompute the rare
    // candidate with the canonical strict CPU HooHash and validate the target.
    const Header80 strict_header=make_header(job,result.nonce);
    const Hash256 strict_hash=crypto::calculate_header80_pow(strict_header);
    if(!mining::hash_meets_target_be(strict_hash,target))return std::nullopt;
    return ShareCandidate{job.job_id,result.nonce,strict_hash};
'''
replace_once(result_marker, result_repl, 'strict candidate validation')

p.write_text(s)
print(f'patched {p}')
