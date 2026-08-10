from pathlib import Path

part07 = Path('native/src/cuda/v1/header80_backend_part07.inc')
text = part07.read_text(encoding='utf-8')

old_blocks = '''    const unsigned int threads = threads_per_block_;
    const unsigned int blocks = static_cast<unsigned int>((count + threads - 1U) / threads);
'''
new_blocks = '''    const unsigned int threads = threads_per_block_;
    constexpr unsigned int kVoltaAsync3ServiceThreads = 96U;
    if (threads <= kVoltaAsync3ServiceThreads) {
        throw std::invalid_argument("volta-async3 requires more than 96 CUDA threads per block");
    }
    const unsigned int worker_threads = threads - kVoltaAsync3ServiceThreads;
    const unsigned int blocks = static_cast<unsigned int>(
        (count + worker_threads - 1U) / worker_threads);
'''
if old_blocks not in text:
    raise SystemExit('part07 launch geometry marker not found')
text = text.replace(old_blocks, new_blocks, 1)

old_cache = '''        check_cuda_header80(
            cudaFuncSetCacheConfig(header80_pow_kernel, cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(header80 monolithic)");'''
new_cache = '''        check_cuda_header80(
            cudaFuncSetCacheConfig(header80_pow_volta_async3_kernel,
                                   cudaFuncCachePreferL1),
            "cudaFuncSetCacheConfig(header80 volta async3)");'''
if old_cache not in text:
    raise SystemExit('part07 cache marker not found')
text = text.replace(old_cache, new_cache, 1)

old_launch = '''    header80_pow_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_),
        static_cast<DeviceShareResult*>(device_result_), count);
    check_cuda_header80(cudaGetLastError(), "header80_pow_kernel launch");'''
new_launch = '''    header80_pow_volta_async3_kernel<<<blocks, threads>>>(
        static_cast<std::uint32_t>(range.begin),
        static_cast<const double*>(device_matrix_),
        static_cast<const double*>(device_scaled_nibble_),
        static_cast<DeviceShareResult*>(device_result_), count);
    check_cuda_header80(cudaGetLastError(),
                        "header80_pow_volta_async3_kernel launch");'''
if old_launch not in text:
    raise SystemExit('part07 kernel launch marker not found')
text = text.replace(old_launch, new_launch, 1)
part07.write_text(text, encoding='utf-8')

main = Path('native/src/app/main_v105.cpp')
text = main.read_text(encoding='utf-8')
if 'PepeW Miner v1.0.5' not in text:
    raise SystemExit('main_v105 console version marker not found')
text = text.replace('PepeW Miner v1.0.5', 'PepeW Miner v1.0.6')
main.write_text(text, encoding='utf-8')

verify07 = part07.read_text(encoding='utf-8')
verify_main = main.read_text(encoding='utf-8')
assert 'kVoltaAsync3ServiceThreads = 96U' in verify07
assert 'header80_pow_volta_async3_kernel<<<blocks, threads>>>' in verify07
assert 'cudaFuncSetCacheConfig(header80_pow_volta_async3_kernel' in verify07
assert 'PepeW Miner v1.0.6' in verify_main
print('V106_VOLTA_ASYNC3_PREPARE=PASS')
