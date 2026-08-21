#!/usr/bin/env python3
from pathlib import Path
import sys

if len(sys.argv) != 2:
    raise SystemExit('usage: fastsolver_v1_patch.py <generated-cuda-source>')

p = Path(sys.argv[1])
text = p.read_text()

replacements = [
    (
        '__device__ void blake80_tail(const std::uint8_t* base,std::uint32_t nonce,std::uint8_t out[32]){',
        '__device__ __noinline__ void blake80_tail(const std::uint8_t* base,std::uint32_t nonce,std::uint8_t out[32]){'
    ),
    (
        '__device__ void blake32(const std::uint8_t in[32],std::uint8_t out[32]){',
        '__device__ __noinline__ void blake32(const std::uint8_t in[32],std::uint8_t out[32]){'
    ),
    (
        '__device__ __forceinline__ void accumulate_row(\n',
        '__device__ __noinline__ void accumulate_row(\n'
    ),
    (
        '__device__ void mix_streamed(const std::uint8_t first[32],std::uint8_t out[32],std::uint32_t nonce_wire){',
        '__device__ __noinline__ void mix_streamed(const std::uint8_t first[32],std::uint8_t out[32],std::uint32_t nonce_wire){'
    ),
]

for old, new in replacements:
    if old not in text:
        raise SystemExit(f'missing transform marker: {old[:80]}')
    text = text.replace(old, new, 1)

old_kernel = '''__global__ void search_kernel(const std::uint8_t* base,std::uint32_t first,DeviceSearchResult* result,std::size_t count){
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
}'''
new_kernel = '''__global__ void search_kernel(const std::uint8_t* base,std::uint32_t first,DeviceSearchResult* result,std::size_t count){
    const std::size_t lane=std::size_t(blockIdx.x)*blockDim.x+threadIdx.x;
    const std::size_t stride=std::size_t(gridDim.x)*blockDim.x;
    for(std::size_t idx=lane;idx<count;idx+=stride){
        if(result->found)return;
        const std::uint32_t nonce=first+static_cast<std::uint32_t>(idx);
        std::uint8_t hash[32];
        hash_one<false>(base,nonce,hash,nullptr,nullptr);
        if(!hash_meets_target_be_device(hash))continue;
        if(atomicCAS(&result->found,0U,1U)==0U){
            result->nonce=nonce;
            #pragma unroll
            for(int i=0;i<32;++i)result->hash[i]=hash[i];
        }
        return;
    }
}'''
if old_kernel not in text:
    raise SystemExit('missing search_kernel marker')
text = text.replace(old_kernel, new_kernel, 1)

old_launch = '''    // Keep baseline launch geometry for the first Kernel-v2 A/B test. Geometry
    // and batch tuning are intentionally isolated into the next experiment.
    constexpr unsigned threads=128;
    const unsigned blocks=static_cast<unsigned>((count+threads-1)/threads);
    search_kernel<<<blocks,threads>>>(device_header,static_cast<std::uint32_t>(range.begin),device_result,count);'''
new_launch = '''    // FastSolver V1: Foztor-class persistent-batch geometry on V100.
    // 2400 x 128 launches 307,200 resident work-items; each lane streams
    // several nonces from the ~1.1M batch instead of creating one CUDA thread
    // for every nonce. Exact HooHash arithmetic is unchanged.
    constexpr unsigned threads=128;
    constexpr unsigned blocks=2400;
    cuda_check(cudaFuncSetCacheConfig(search_kernel,cudaFuncCachePreferL1),"search PreferL1");
    cuda_check(cudaFuncSetAttribute(search_kernel,cudaFuncAttributePreferredSharedMemoryCarveout,0),"search carveout 0");
    search_kernel<<<blocks,threads>>>(device_header,static_cast<std::uint32_t>(range.begin),device_result,count);'''
if old_launch not in text:
    raise SystemExit('missing FastSolver launch marker')
text = text.replace(old_launch, new_launch, 1)

p.write_text(text)
print(f'patched {p}')
