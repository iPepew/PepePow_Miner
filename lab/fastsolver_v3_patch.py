#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: fastsolver_v3_patch.py <generated-cu>')

p = Path(sys.argv[1])
s = p.read_text()

def replace_once(old: str, new: str, label: str) -> None:
    global s
    if old not in s:
        raise SystemExit(f'{label} marker missing')
    s = s.replace(old, new, 1)

replace_once(
    '__device__ double d_exp_sincossum_lut[kFastPhaseLutIntervals + 1U];\n',
    '__device__ double d_exp_sincossum_lut[kFastPhaseLutIntervals + 1U];\n'
    '__device__ double d_sin2_lut[kFastPhaseLutIntervals + 1U];\n',
    'sin2 LUT declaration')

exp_init = '''__global__ void init_exp_sincossum_lut_kernel(){
    const unsigned i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i>kFastPhaseLutIntervals)return;
    const double phase=(2.0*kPi*static_cast<double>(i))/static_cast<double>(kFastPhaseLutIntervals);
    double sn,cs;
    sincos(phase,&sn,&cs);
    d_exp_sincossum_lut[i]=exp(sn+cs);
}
'''
replace_once(
    exp_init,
    exp_init + '''
__global__ void init_sin2_lut_kernel(){
    const unsigned i=blockIdx.x*blockDim.x+threadIdx.x;
    if(i>kFastPhaseLutIntervals)return;
    const double phase=(2.0*kPi*static_cast<double>(i))/static_cast<double>(kFastPhaseLutIntervals);
    const double sn=sin(phase);
    d_sin2_lut[i]=sn*sn;
}
''',
    'sin2 LUT init')

old_sin2 = '''__device__ __noinline__ double fast_sin2(double y){
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
'''
new_sin2 = '''__device__ __noinline__ double fast_sin2(double y){
    unsigned long long frac;
    if(!fast_phase_frac64(y,&frac)){
        const double sn=sin(y);return sn*sn;
    }
    constexpr unsigned long long n=static_cast<unsigned long long>(kFastPhaseLutIntervals);
    unsigned idx=static_cast<unsigned>(__umul64hi(frac,n));
    if(idx>=kFastPhaseLutIntervals)idx=kFastPhaseLutIntervals-1U;
    const unsigned long long cell=frac*n;
    const double t=__ull2double_rn(cell)*0x1p-64;
    const double a=__ldg(&d_sin2_lut[idx]);
    const double b=__ldg(&d_sin2_lut[idx+1U]);
    return a+(b-a)*t;
}
'''
replace_once(old_sin2, new_sin2, 'fast sin2 LUT lookup')

old_init = '''        init_exp_sincossum_lut_kernel<<<b,t>>>();
        cuda_check(cudaGetLastError(),"init FastSolver V2 exp(sin+cos) LUT");
        cuda_check(cudaDeviceSynchronize(),"sync FastSolver V2 exp(sin+cos) LUT");
        lut_ready[device_index_]=true;
'''
new_init = '''        init_exp_sincossum_lut_kernel<<<b,t>>>();
        cuda_check(cudaGetLastError(),"init FastSolver V3 exp(sin+cos) LUT");
        init_sin2_lut_kernel<<<b,t>>>();
        cuda_check(cudaGetLastError(),"init FastSolver V3 sin2 LUT");
        cuda_check(cudaDeviceSynchronize(),"sync FastSolver V3 dual LUT");
        lut_ready[device_index_]=true;
'''
replace_once(old_init, new_init, 'dual LUT initialization')

s = s.replace('FastSolver V2:', 'FastSolver V3:', 1)
p.write_text(s)
print(f'patched FastSolver V3 dual-LUT hotpath: {p}')
