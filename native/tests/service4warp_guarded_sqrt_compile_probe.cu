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
    // Observed HooHash high-branch inputs are overwhelmingly >=2^40. Keep all
    // smaller/subnormal/non-finite values on the exact consensus path.
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

struct Scratch{
    unsigned count;
    double y[kThreads];
    double scale[kThreads];
    double result[kThreads];
    double error[kThreads];
};
}

extern "C" __global__ __launch_bounds__(704,1)
void service4warp_guarded_sqrt_compile_probe(const double* y,const double* scale,double* out,double* err,unsigned n){
    __shared__ Scratch s;
    if(threadIdx.x==0U) s.count=0U;
    __syncthreads();
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
    if(active){out[idx]=s.result[slot];err[idx]=s.error[slot];}
}
