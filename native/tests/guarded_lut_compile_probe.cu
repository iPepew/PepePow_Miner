#include "../src/cuda/guarded_lut_primitives.cuh"

__device__ double d_exp_probe[pepepow::cuda_guarded_lut::kExpLutIntervals + 1U];
__device__ double d_sin2_probe[pepepow::cuda_guarded_lut::kSin2LutIntervals + 1U];

__global__ void guarded_lut_compile_probe(double y, double* out) {
    double v0 = 0.0, e0 = 0.0;
    double v1 = 0.0, e1 = 0.0;
    const bool ok0 = pepepow::cuda_guarded_lut::exp_sincos_approx(y, d_exp_probe, v0, e0);
    const bool ok1 = pepepow::cuda_guarded_lut::sin2_approx(y, d_sin2_probe, v1, e1);
    if (threadIdx.x == 0 && blockIdx.x == 0) {
        out[0] = ok0 ? v0 : -1.0;
        out[1] = ok1 ? v1 : -1.0;
        out[2] = e0 + e1;
    }
}
