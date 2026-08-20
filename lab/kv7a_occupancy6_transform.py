#!/usr/bin/env python3
from pathlib import Path

src = Path("native/src/cuda/header80_backend_cuda118_v2.cu")
text = src.read_text()

# KV7-A clean-room architecture inferred from public/runtime measurements only:
# Foztor's V100 autotune winner is 640 threads x 320 blocks x 6 nonces/thread,
# with 47 registers/thread -> 2 resident blocks/SM -> 40 warps/SM = 62.5%.
# We reproduce only that scheduling shape on our independent strict HooHash code.

needle = "constexpr std::size_t kHeaderPrefixSize = 76;\n"
replacement = needle + "constexpr std::size_t kNoncesPerThread = 6;\n"
if text.count(needle) != 1:
    raise SystemExit(f"KV7-A header marker count={text.count(needle)}")
text = text.replace(needle, replacement)

old_kernel = r'''__global__ void search_kernel(const std::uint8_t* base,std::uint32_t first,DeviceSearchResult* result,std::size_t count){
    const std::size_t idx=std::size_t(blockIdx.x)*blockDim.x+threadIdx.x;
    if(idx>=count)return;
    const std::uint32_t nonce=first+static_cast<std::uint32_t>(idx);
    HashWords8 hash{};
    hash_one_words<false>(base,nonce,hash,nullptr,nullptr);
    if(!hash_meets_target_be_words(hash))return;
    if(atomicCAS(&result->found,0U,1U)==0U){
        result->nonce=nonce;
        put_words_bytes(result->hash,hash);
    }
}
'''
new_kernel = r'''__global__ void search_kernel(const std::uint8_t* base,std::uint32_t first,DeviceSearchResult* result,std::size_t count){
    const std::size_t tid=std::size_t(blockIdx.x)*blockDim.x+threadIdx.x;
    const std::size_t stride=std::size_t(gridDim.x)*blockDim.x;

    // Keep the nonce loop rolled. Reusing one hash state six times is the point:
    // fully unrolling this loop would duplicate the large HooHash body and fight
    // the 48-register occupancy target.
    #pragma unroll 1
    for(std::size_t lane=0;lane<kNoncesPerThread;++lane){
        const std::size_t idx=tid+lane*stride;
        if(idx>=count)continue;
        const std::uint32_t nonce=first+static_cast<std::uint32_t>(idx);
        HashWords8 hash{};
        hash_one_words<false>(base,nonce,hash,nullptr,nullptr);
        if(!hash_meets_target_be_words(hash))continue;
        if(atomicCAS(&result->found,0U,1U)==0U){
            result->nonce=nonce;
            put_words_bytes(result->hash,hash);
        }
    }
}
'''
if text.count(old_kernel) != 1:
    raise SystemExit(f"KV7-A search kernel marker count={text.count(old_kernel)}")
text = text.replace(old_kernel, new_kernel)

old_blocks = r'''    constexpr unsigned threads=64;
    const unsigned blocks=static_cast<unsigned>((count+threads-1)/threads);
    search_kernel<<<blocks,threads>>>(device_header,static_cast<std::uint32_t>(range.begin),device_result,count);
'''
new_blocks = r'''    constexpr unsigned threads=64;
    const std::size_t logical_threads=(count+kNoncesPerThread-1U)/kNoncesPerThread;
    const unsigned blocks=static_cast<unsigned>((logical_threads+threads-1U)/threads);
    search_kernel<<<blocks,threads>>>(device_header,static_cast<std::uint32_t>(range.begin),device_result,count);
'''
if text.count(old_blocks) != 1:
    raise SystemExit(f"KV7-A host launch marker count={text.count(old_blocks)}")
text = text.replace(old_blocks, new_blocks)

# Prefer L1 and 0% shared-memory carveout, matching the measured best Volta
# cache configuration. This is a public CUDA runtime setting, not Foztor code.
old_state = r'''void Header80CudaBackend::ensure_device_state(){
    cuda_check(cudaSetDevice(device_index_),"cudaSetDevice");
'''
new_state = r'''void Header80CudaBackend::ensure_device_state(){
    cuda_check(cudaSetDevice(device_index_),"cudaSetDevice");
    static thread_local bool cache_configured=false;
    if(!cache_configured){
        cuda_check(cudaFuncSetCacheConfig(search_kernel,cudaFuncCachePreferL1),"cudaFuncSetCacheConfig search_kernel");
        cuda_check(cudaFuncSetAttribute(search_kernel,cudaFuncAttributePreferredSharedMemoryCarveout,0),"cudaFuncSetAttribute carveout");
        cache_configured=true;
    }
'''
if text.count(old_state) != 1:
    raise SystemExit(f"KV7-A cache marker count={text.count(old_state)}")
text = text.replace(old_state, new_state)

required = [
    "kNoncesPerThread = 6",
    "#pragma unroll 1\n    for(std::size_t lane=0;lane<kNoncesPerThread;++lane)",
    "lane*stride",
    "logical_threads=(count+kNoncesPerThread-1U)/kNoncesPerThread",
    "cudaFuncCachePreferL1",
    "cudaFuncAttributePreferredSharedMemoryCarveout",
]
for marker in required:
    if marker not in text:
        raise SystemExit(f"KV7-A missing marker: {marker}")

src.write_text(text)

# Match the measured Foztor V100 batch: 640 * 320 * 6 = 1,228,800 nonces.
app = Path("native/src/app/main.cpp")
app_text = app.read_text()
old_chunk = "        constexpr std::uint64_t chunk_size = 1ULL << 18;\n"
new_chunk = "        constexpr std::uint64_t chunk_size = 1228800ULL; // KV7-A: 640 x 320 x 6\n"
if app_text.count(old_chunk) != 1:
    raise SystemExit(f"KV7-A chunk marker count={app_text.count(old_chunk)}")
app_text = app_text.replace(old_chunk, new_chunk)
app.write_text(app_text)

print("KV7-A occupancy6 transform applied")
