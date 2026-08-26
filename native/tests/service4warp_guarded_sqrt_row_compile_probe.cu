#include <cuda_runtime.h>
#include <cstdint>
#include <cmath>

namespace {
constexpr unsigned kThreads=704U;
constexpr unsigned kServiceThreads=128U;
constexpr double kInvSqrt2=0.707106781186547524400844362104849039;

__device__ __forceinline__ bool sqrt_elision_bound(double y,double scale,double& value,double& abs_error){
    const double a=fabs(y);
    const unsigned long long bits=static_cast<unsigned long long>(__double_as_longlong(a));
    const unsigned exp=static_cast<unsigned>((bits>>52U)&0x7ffULL);
    if(exp==0U || exp==0x7ffU || exp<1063U){
        value=1.0/sqrt(a+1.0);
        abs_error=0.0;
        return false;
    }
    const int k=static_cast<int>(exp)-1023;
    const int half=k>>1;
    const unsigned power_exp=static_cast<unsigned>(1023-half);
    double bound=__longlong_as_double(static_cast<long long>(static_cast<unsigned long long>(power_exp)<<52U));
    if(k&1) bound*=kInvSqrt2;
    value=0.0;
    abs_error=bound*fabs(scale);
    return true;
}

__device__ __forceinline__ bool same_integer_interval(double sum,double radius){
    if(!(radius>=0.0) || !isfinite(sum) || !isfinite(radius)) return false;
    const double lo=fmax(0.0,sum-radius);
    const double hi=sum+radius;
    return static_cast<unsigned long long>(lo)==static_cast<unsigned long long>(hi);
}

__device__ __forceinline__ bool same_cold_interval(double sum,double radius){
    if(!(radius>=0.0) || !isfinite(sum) || !isfinite(radius)) return false;
    // Resource-model guard only: production path uses exact bit-based sw predicate.
    const double lo=fmax(0.0,sum-radius);
    const double hi=sum+radius;
    const double flo=fmod(lo/1024.0,1.0);
    const double fhi=fmod(hi/1024.0,1.0);
    return (flo<=0.02)==(fhi<=0.02) && (hi-lo)<16.0;
}

struct Scratch{
    double y[kThreads];
    double scale[kThreads];
    double result[kThreads];
    double error[kThreads];
};
}

extern "C" __global__ __launch_bounds__(704,1)
void service4warp_guarded_sqrt_row_compile_probe(const double* y,const double* scale,double* out,unsigned* replay,unsigned n){
    __shared__ Scratch s;
    const unsigned idx=blockIdx.x*blockDim.x+threadIdx.x;
    const bool active=idx<n;
    const unsigned slot=threadIdx.x;
    if(active){s.y[slot]=y[idx];s.scale[slot]=scale[idx];}
    __syncthreads();

    if(threadIdx.x<kServiceThreads){
        for(unsigned i=threadIdx.x;i<blockDim.x;i+=kServiceThreads){
            if(blockIdx.x*blockDim.x+i<n){
                double v=0.0,e=0.0;
                sqrt_elision_bound(s.y[i],s.scale[i],v,e);
                s.result[i]=v*s.scale[i];
                s.error[i]=e;
            }
        }
    }
    __syncthreads();

    if(active){
        double sum=0.0;
        double radius=0.0;
        bool ambiguous=false;
        #pragma unroll 1
        for(int cell=0;cell<64;++cell){
            sum += s.result[slot];
            radius += s.error[slot];
            if(!same_cold_interval(sum,radius)) ambiguous=true;
        }
        if(!same_integer_interval(sum,radius)) ambiguous=true;
        out[idx]=sum;
        replay[idx]=ambiguous?1U:0U;
    }
}
