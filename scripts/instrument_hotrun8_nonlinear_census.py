#!/usr/bin/env python3
from pathlib import Path

# Low-overhead exact census for cold-path nonlinear selector behavior.
# Sampling is per nonce (first_pass[0] low 12 bits == 0). We do not alter
# consensus arithmetic: the real safe_nonlinear(x) call remains untouched.
# For sampled cold cells only, selector/y are recomputed in parallel solely to
# count branch frequencies and argument ranges. All counters remain thread-local
# and are flushed once per sampled nonce.

hot = Path('native/src/cuda/v1/header80_hotrun8.inc')
s = hot.read_text()

anchor = '''// Exact hot-run width-8 candidate. This file is included inside the anonymous
// CUDA namespace, before host methods. Consensus arithmetic is unchanged:
'''
insert = anchor + '''#if defined(PEPEPOW_CUDA_NONLINEAR_CENSUS) && PEPEPOW_CUDA_NONLINEAR_CENSUS
__device__ unsigned long long g_nlc_samples = 0ULL;
__device__ unsigned long long g_nlc_calls = 0ULL;
__device__ unsigned long long g_nlc_exp_calls = 0ULL;
__device__ unsigned long long g_nlc_sin2_calls = 0ULL;
__device__ unsigned long long g_nlc_rsqrt_calls = 0ULL;
__device__ unsigned long long g_nlc_exp_y_min_bits = 0x7ff0000000000000ULL;
__device__ unsigned long long g_nlc_exp_y_max_bits = 0ULL;
__device__ unsigned long long g_nlc_sin2_y_min_bits = 0x7ff0000000000000ULL;
__device__ unsigned long long g_nlc_sin2_y_max_bits = 0ULL;
__device__ unsigned long long g_nlc_rsqrt_arg_min_bits = 0x7ff0000000000000ULL;
__device__ unsigned long long g_nlc_rsqrt_arg_max_bits = 0ULL;

__device__ __forceinline__ unsigned long long nlc_ordered_positive_bits(double v) {
    return static_cast<unsigned long long>(__double_as_longlong(v));
}
__device__ __forceinline__ unsigned long long nlc_ordered_signed_bits(double v) {
    const unsigned long long b = static_cast<unsigned long long>(__double_as_longlong(v));
    return (b & 0x8000000000000000ULL) ? ~b : (b ^ 0x8000000000000000ULL);
}
__device__ __forceinline__ double nlc_signed_from_ordered(unsigned long long o) {
    const unsigned long long b = (o & 0x8000000000000000ULL)
        ? (o ^ 0x8000000000000000ULL) : ~o;
    return __longlong_as_double(static_cast<long long>(b));
}
#endif
'''
if anchor not in s:
    raise SystemExit('header anchor not found')
s = s.replace(anchor, insert, 1)

old_sig = '''    int row, const std::uint32_t first_pass[8], double hash_mod_fp64,
    double nonce_mod, HooHashSwState& sw) {'''
new_sig = '''    int row, const std::uint32_t first_pass[8], double hash_mod_fp64,
    double nonce_mod, HooHashSwState& sw, bool nlc_sample,
    unsigned long long& nlc_calls,
    unsigned long long& nlc_exp_calls,
    unsigned long long& nlc_sin2_calls,
    unsigned long long& nlc_rsqrt_calls,
    unsigned long long& nlc_exp_y_min,
    unsigned long long& nlc_exp_y_max,
    unsigned long long& nlc_sin2_y_min,
    unsigned long long& nlc_sin2_y_max,
    unsigned long long& nlc_rsqrt_arg_min,
    unsigned long long& nlc_rsqrt_arg_max) {'''
if old_sig not in s:
    raise SystemExit('matrix_row signature anchor not found')
s = s.replace(old_sig, new_sig, 1)

cold = '''                const double value = nibble_to_double(nibble);
                const double x = matrix[cell] * hash_mod_fp64 * value + nonce_mod;
                sum += safe_nonlinear(x) * value * 1234.0;
'''
cold_new = '''                const double value = nibble_to_double(nibble);
                const double x = matrix[cell] * hash_mod_fp64 * value + nonce_mod;
#if defined(PEPEPOW_CUDA_NONLINEAR_CENSUS) && PEPEPOW_CUDA_NONLINEAR_CENSUS
                if (nlc_sample) {
                    const double one_base = x * kTransformMultiplier * 0.125;
                    const HooHashSelectorParts selector = decode_selector_parts(one_base);
                    const double two = selector.two;
                    double y;
                    if (two < 0.25) y = x + (1.0 + two);
                    else if (two < 0.50) y = x - (1.0 + two);
                    else if (two < 0.75) y = x * (1.0 + two);
                    else y = x / (1.0 + two);
                    ++nlc_calls;
                    if (selector.one_region == 0U) {
                        ++nlc_exp_calls;
                        const unsigned long long ob = nlc_ordered_signed_bits(y);
                        nlc_exp_y_min = min(nlc_exp_y_min, ob);
                        nlc_exp_y_max = max(nlc_exp_y_max, ob);
                    } else if (selector.one_region == 1U) {
                        ++nlc_sin2_calls;
                        const unsigned long long ob = nlc_ordered_signed_bits(y);
                        nlc_sin2_y_min = min(nlc_sin2_y_min, ob);
                        nlc_sin2_y_max = max(nlc_sin2_y_max, ob);
                    } else {
                        ++nlc_rsqrt_calls;
                        const double a = fabs(y) + 1.0;
                        const unsigned long long ob = nlc_ordered_positive_bits(a);
                        nlc_rsqrt_arg_min = min(nlc_rsqrt_arg_min, ob);
                        nlc_rsqrt_arg_max = max(nlc_rsqrt_arg_max, ob);
                    }
                }
#endif
                sum += safe_nonlinear(x) * value * 1234.0;
'''
if cold not in s:
    raise SystemExit('cold nonlinear anchor not found')
s = s.replace(cold, cold_new, 1)

setup = '''    HooHashSwState sw = initial_sw_state();

    #pragma unroll 1
    for (int pair = 0; pair < 32; ++pair) {'''
setup_new = '''    HooHashSwState sw = initial_sw_state();
#if defined(PEPEPOW_CUDA_NONLINEAR_CENSUS) && PEPEPOW_CUDA_NONLINEAR_CENSUS
    const bool nlc_sample = (first_pass[0] & 0x0fffU) == 0U;
    unsigned long long nlc_calls = 0ULL, nlc_exp_calls = 0ULL, nlc_sin2_calls = 0ULL, nlc_rsqrt_calls = 0ULL;
    unsigned long long nlc_exp_y_min = 0xffffffffffffffffULL, nlc_exp_y_max = 0ULL;
    unsigned long long nlc_sin2_y_min = 0xffffffffffffffffULL, nlc_sin2_y_max = 0ULL;
    unsigned long long nlc_rsqrt_arg_min = 0x7ff0000000000000ULL, nlc_rsqrt_arg_max = 0ULL;
#else
    const bool nlc_sample = false;
    unsigned long long nlc_calls = 0ULL, nlc_exp_calls = 0ULL, nlc_sin2_calls = 0ULL, nlc_rsqrt_calls = 0ULL;
    unsigned long long nlc_exp_y_min = 0ULL, nlc_exp_y_max = 0ULL, nlc_sin2_y_min = 0ULL, nlc_sin2_y_max = 0ULL;
    unsigned long long nlc_rsqrt_arg_min = 0ULL, nlc_rsqrt_arg_max = 0ULL;
#endif

    #pragma unroll 1
    for (int pair = 0; pair < 32; ++pair) {'''
if setup not in s:
    raise SystemExit('mix setup anchor not found')
s = s.replace(setup, setup_new, 1)

old_call = '''            hash_mod_fp64, nonce_mod, sw);'''
new_call = '''            hash_mod_fp64, nonce_mod, sw, nlc_sample,
            nlc_calls, nlc_exp_calls, nlc_sin2_calls, nlc_rsqrt_calls,
            nlc_exp_y_min, nlc_exp_y_max, nlc_sin2_y_min, nlc_sin2_y_max,
            nlc_rsqrt_arg_min, nlc_rsqrt_arg_max);'''
if s.count(old_call) != 2:
    raise SystemExit(f'expected 2 row calls, got {s.count(old_call)}')
s = s.replace(old_call, new_call, 2)

mix_tail = '''        mixed[pair >> 2] ^=
            static_cast<std::uint32_t>(combined & 0xffU) << shift;
    }
}
'''
mix_tail_new = '''        mixed[pair >> 2] ^=
            static_cast<std::uint32_t>(combined & 0xffU) << shift;
    }
#if defined(PEPEPOW_CUDA_NONLINEAR_CENSUS) && PEPEPOW_CUDA_NONLINEAR_CENSUS
    if (nlc_sample) {
        atomicAdd(&g_nlc_samples, 1ULL);
        atomicAdd(&g_nlc_calls, nlc_calls);
        atomicAdd(&g_nlc_exp_calls, nlc_exp_calls);
        atomicAdd(&g_nlc_sin2_calls, nlc_sin2_calls);
        atomicAdd(&g_nlc_rsqrt_calls, nlc_rsqrt_calls);
        if (nlc_exp_calls) {
            atomicMin(&g_nlc_exp_y_min_bits, nlc_exp_y_min);
            atomicMax(&g_nlc_exp_y_max_bits, nlc_exp_y_max);
        }
        if (nlc_sin2_calls) {
            atomicMin(&g_nlc_sin2_y_min_bits, nlc_sin2_y_min);
            atomicMax(&g_nlc_sin2_y_max_bits, nlc_sin2_y_max);
        }
        if (nlc_rsqrt_calls) {
            atomicMin(&g_nlc_rsqrt_arg_min_bits, nlc_rsqrt_arg_min);
            atomicMax(&g_nlc_rsqrt_arg_max_bits, nlc_rsqrt_arg_max);
        }
    }
#endif
}
'''
if mix_tail not in s:
    raise SystemExit('mix tail anchor not found')
s = s.replace(mix_tail, mix_tail_new, 1)
hot.write_text(s)

part = Path('native/src/cuda/v1/header80_backend_part07.inc')
p = part.read_text()
reset_anchor = '''    constexpr unsigned int threads = static_cast<unsigned int>(PEPEPOW_CUDA_THREADS);
    const unsigned int blocks = static_cast<unsigned int>((count + threads - 1U) / threads);
'''
reset = reset_anchor + '''
#if defined(PEPEPOW_CUDA_NONLINEAR_CENSUS) && PEPEPOW_CUDA_NONLINEAR_CENSUS
    const unsigned long long z = 0ULL;
    const unsigned long long inf = 0x7ff0000000000000ULL;
    check_cuda_header80(cudaMemcpyToSymbol(g_nlc_samples, &z, sizeof(z)), "reset nlc samples");
    check_cuda_header80(cudaMemcpyToSymbol(g_nlc_calls, &z, sizeof(z)), "reset nlc calls");
    check_cuda_header80(cudaMemcpyToSymbol(g_nlc_exp_calls, &z, sizeof(z)), "reset nlc exp calls");
    check_cuda_header80(cudaMemcpyToSymbol(g_nlc_sin2_calls, &z, sizeof(z)), "reset nlc sin2 calls");
    check_cuda_header80(cudaMemcpyToSymbol(g_nlc_rsqrt_calls, &z, sizeof(z)), "reset nlc rsqrt calls");
    check_cuda_header80(cudaMemcpyToSymbol(g_nlc_exp_y_min_bits, &inf, sizeof(inf)), "reset nlc exp min");
    check_cuda_header80(cudaMemcpyToSymbol(g_nlc_exp_y_max_bits, &z, sizeof(z)), "reset nlc exp max");
    check_cuda_header80(cudaMemcpyToSymbol(g_nlc_sin2_y_min_bits, &inf, sizeof(inf)), "reset nlc sin2 min");
    check_cuda_header80(cudaMemcpyToSymbol(g_nlc_sin2_y_max_bits, &z, sizeof(z)), "reset nlc sin2 max");
    check_cuda_header80(cudaMemcpyToSymbol(g_nlc_rsqrt_arg_min_bits, &inf, sizeof(inf)), "reset nlc rsqrt min");
    check_cuda_header80(cudaMemcpyToSymbol(g_nlc_rsqrt_arg_max_bits, &z, sizeof(z)), "reset nlc rsqrt max");
#endif
'''
if reset_anchor not in p:
    raise SystemExit('host reset anchor not found')
p = p.replace(reset_anchor, reset, 1)

report_anchor = '''    DeviceShareResult host_result{};
'''
report = '''#if defined(PEPEPOW_CUDA_NONLINEAR_CENSUS) && PEPEPOW_CUDA_NONLINEAR_CENSUS
    unsigned long long ns=0,nc=0,ne=0,n2=0,nr=0,emin=0,emax=0,smin=0,smax=0,rmin=0,rmax=0;
    check_cuda_header80(cudaMemcpyFromSymbol(&ns,g_nlc_samples,sizeof(ns)), "copy nlc samples");
    check_cuda_header80(cudaMemcpyFromSymbol(&nc,g_nlc_calls,sizeof(nc)), "copy nlc calls");
    check_cuda_header80(cudaMemcpyFromSymbol(&ne,g_nlc_exp_calls,sizeof(ne)), "copy nlc exp calls");
    check_cuda_header80(cudaMemcpyFromSymbol(&n2,g_nlc_sin2_calls,sizeof(n2)), "copy nlc sin2 calls");
    check_cuda_header80(cudaMemcpyFromSymbol(&nr,g_nlc_rsqrt_calls,sizeof(nr)), "copy nlc rsqrt calls");
    check_cuda_header80(cudaMemcpyFromSymbol(&emin,g_nlc_exp_y_min_bits,sizeof(emin)), "copy nlc exp min");
    check_cuda_header80(cudaMemcpyFromSymbol(&emax,g_nlc_exp_y_max_bits,sizeof(emax)), "copy nlc exp max");
    check_cuda_header80(cudaMemcpyFromSymbol(&smin,g_nlc_sin2_y_min_bits,sizeof(smin)), "copy nlc sin2 min");
    check_cuda_header80(cudaMemcpyFromSymbol(&smax,g_nlc_sin2_y_max_bits,sizeof(smax)), "copy nlc sin2 max");
    check_cuda_header80(cudaMemcpyFromSymbol(&rmin,g_nlc_rsqrt_arg_min_bits,sizeof(rmin)), "copy nlc rsqrt min");
    check_cuda_header80(cudaMemcpyFromSymbol(&rmax,g_nlc_rsqrt_arg_max_bits,sizeof(rmax)), "copy nlc rsqrt max");
    const double exp_min = ne ? nlc_signed_from_ordered(emin) : 0.0;
    const double exp_max = ne ? nlc_signed_from_ordered(emax) : 0.0;
    const double sin2_min = n2 ? nlc_signed_from_ordered(smin) : 0.0;
    const double sin2_max = n2 ? nlc_signed_from_ordered(smax) : 0.0;
    const double rsqrt_min = nr ? __longlong_as_double(static_cast<long long>(rmin)) : 0.0;
    const double rsqrt_max = nr ? __longlong_as_double(static_cast<long long>(rmax)) : 0.0;
    std::fprintf(stderr,
        "PEPEW_NONLINEAR_CENSUS count=%zu samples=%llu calls=%llu exp_calls=%llu sin2_calls=%llu rsqrt_calls=%llu exp_y_min=%.17g exp_y_max=%.17g sin2_y_min=%.17g sin2_y_max=%.17g rsqrt_arg_min=%.17g rsqrt_arg_max=%.17g\\n",
        count,ns,nc,ne,n2,nr,exp_min,exp_max,sin2_min,sin2_max,rsqrt_min,rsqrt_max);
#endif

    DeviceShareResult host_result{};
'''
if report_anchor not in p:
    raise SystemExit('host report anchor not found')
p = p.replace(report_anchor, report, 1)
part.write_text(p)
print('instrumented low-overhead HotRun8 nonlinear census')
