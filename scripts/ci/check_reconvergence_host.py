#!/usr/bin/env python3
"""Pinned CUDA-body coroutine check on CPU. No GPU/codegen/libdevice performance claims."""
import argparse,hashlib,json,pathlib,subprocess,tempfile,sys
PINS={
 'native/src/cuda/v1/header80_backend_part02.inc':'01beeeb3e6e1d7b9a0af58c1c8231cde507650ca',
 'native/src/cuda/v1/header80_hotrun8_fusion.inc':'0332314f6b18c86995273020d90484c2b5800a6a',
 'native/src/cuda/v1/header80_hotrun8.inc':'7d10b86bc58b5f75fae4647705c6bf0fcf634444',
 'native/src/crypto/hoohash_reference.cpp':'b71fcfb8775a534db14084f8cd4fcb3277d4fa23',
 'native/include/pepepow/crypto/hoohash_reference.hpp':'c32830fb513f7843c92bff0a8a485f76c06f6c27',
}
HEADER_PINS={"native/src/core/header_builder.cpp":"548e5806f8c94442fb7dc07018044a7892d93c5f","native/include/pepepow/core/header_builder.hpp":"e9ec1bc963330ab1e33f7b2bb8fd5f8e1cc7458d","native/include/pepepow/core/types.hpp":"ce512d209426179099dbd917fbcba47d61a041a7","native/src/benchmark/header80_benchmark.cpp":"984fe247f231c70a5046b29845ad581485e3f8c3","native/src/crypto/pow.cpp":"cf4dc0fee5a01c21ecefce1390971adb527b9d38"}
BLAKE3_PINS={"blake3.c":"00f91f444922df7c8e7b5ff69343852cbbf4c613","blake3.h":"423154ff75858d58cdb3f946a59426f8d9212012","blake3_impl.h":"88e71e41e90f3f3cca4d39f19d50e74325fb5ce2","blake3_portable.c":"062dd1b47fb6424f4d3db4c6edd2f90efcb92973","blake3_dispatch.c":"14dfbbe0c8f385296adf691643481b87e8768522"}
SOURCE='69982736eb073a8df53fbdbe4dc02509fc760807'
def extract(text,name):
    at=text.index(name+'(');start=text.rfind('__device__',0,at)
    begin=text.index('{',at);depth=1;end=begin+1
    while depth and end<len(text):
        if text[end]=='{':depth+=1
        elif text[end]=='}':depth-=1
        end+=1
    if depth or start<0:raise RuntimeError('SOURCE_FUNCTION_EXTRACTION')
    return text[start:end]
def replace_once(text,old,new):
    if text.count(old)!=1:raise RuntimeError('SOURCE_REPLACEMENT_CONTRACT')
    return text.replace(old,new,1)
def generate(root):
    contents={}
    for name,expected in PINS.items():
        data=(root/name).read_bytes()
        sha=hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
        if sha!=expected:raise RuntimeError('PINNED_SOURCE_BLOB_MISMATCH:'+name)
        contents[name]=data.decode('utf-8')
    body=extract(contents['native/src/cuda/v1/header80_hotrun8_fusion.inc'],'hoohash_mix_words_hotrun8_reconverged')
    body=replace_once(body,'__device__ __noinline__ void','Task')
    body=replace_once(body,'__activemask()','active_mask')
    if body.count('__syncwarp(warp_mask);')!=2:raise RuntimeError('SOURCE_BARRIER_COUNT')
    body=body.replace('__syncwarp(warp_mask);','co_await SyncAwaiter{warp_mask,0,pending};',1)
    body=body.replace('__syncwarp(warp_mask);','co_await SyncAwaiter{warp_mask,1};',1)
    body=replace_once(body,'__any_sync(warp_mask, !done)','co_await VoteAwaiter{warp_mask,!done}')
    reference=replace_once(contents['native/src/crypto/hoohash_reference.cpp'],
        'sw = product[i] / 1024.0 - std::floor(product[i] / 1024.0);',
        'sw = product[i] / 1024.0 - std::floor(product[i] / 1024.0);\n            ::record_reference(i,j,product[i],sw);')
    hotrun=contents['native/src/cuda/v1/header80_hotrun8.inc']
    helpers=extract(hotrun,'hotrun8_warm_contribution')+'\n'+extract(hotrun,'hotrun8_word_nibble')
    state_source=contents['native/src/cuda/v1/header80_backend_part02.inc']
    marker='#else\nusing HooHashSwState = bool;'
    if state_source.count(marker)!=1:raise RuntimeError('SW_MODE3_EXTRACTION')
    state_section=state_source.split(marker,1)[1].split('#endif',1)[0]
    state_helpers='using HooHashSwState = bool;'+state_section
    state_helpers=replace_once(state_helpers,'state = (scaled - static_cast<double>(whole)) <= 0.02;',
                               'state = (scaled - static_cast<double>(whole)) <= 0.02;\n    trace_gpu_sw(sum,state);')
    harness=(root/'native/tests/reconvergence_host_harness.inc').read_text()
    def assemble(candidate):
        return replace_once(replace_once(replace_once(replace_once(harness,'// @REFERENCE@',reference),'// @HELPERS@',helpers),'// @SW_HELPERS@',state_helpers),'// @CANDIDATE@',candidate)
    return assemble,body
def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('root',nargs='?',type=pathlib.Path,default=pathlib.Path(__file__).resolve().parents[2])
    parser.add_argument('--blake3-root',type=pathlib.Path)
    args=parser.parse_args();root=args.root.resolve()
    assemble,body=generate(root)
    mutations=[
      ('missing_second_barrier',replace_once(body,'co_await SyncAwaiter{warp_mask,1};','/* removed second barrier */'),'collective slot order'),
      ('finished_lane_early_exit',replace_once(body,'co_await SyncAwaiter{warp_mask,0,pending};','if (done) co_return;\n        co_await SyncAwaiter{warp_mask,0,pending};'),'early lane completion before cohort'),
      ('skipped_zero_state_update',body.replace('update_sw_state(sw, sum);','if (nibble != 0U) update_sw_state(sw, sum);',1),'per-cell FP64/SW trace mismatch'),
    ]
    mutations.append(('incorrect_sw_mode3_predicate',body,'per-cell FP64/SW trace mismatch'))
    mutations.append(('incorrect_pending_observer',body,'frontier pending-call conservation'))
    result=None;detected=[]
    with tempfile.TemporaryDirectory(prefix='pepew-host-reconvergence-') as directory:
        work=pathlib.Path(directory)
        link=[]
        if args.blake3_root:
            dep=args.blake3_root.resolve()
            for names,base in ((HEADER_PINS,root),(BLAKE3_PINS,dep)):
                for path,expected in names.items():
                    data=(base/path).read_bytes()
                    if hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()!=expected:raise RuntimeError('HEADER80_DEPENDENCY_IDENTITY:'+path)
            for source_name in ('blake3.c','blake3_portable.c','blake3_dispatch.c'):
                obj=work/(source_name+'.o')
                subprocess.run(['gcc','-std=c11','-O2','-DBLAKE3_NO_SSE2','-DBLAKE3_NO_SSE41','-DBLAKE3_NO_AVX2','-DBLAKE3_NO_AVX512','-DBLAKE3_USE_NEON=0','-I',str(dep),'-c',str(dep/source_name),'-o',str(obj)],check=True,timeout=30,capture_output=True,text=True)
                link.append(str(obj))
        cases=[('baseline',body,None)]+mutations
        if args.blake3_root:cases.append(('header80_fixture_baseline',body,None))
        for name,candidate,error in cases:
            source=work/(name+'.cpp');binary=work/name
            assembled=assemble(candidate)
            if name=='incorrect_sw_mode3_predicate':
                assembled=replace_once(assembled,'state = (scaled - static_cast<double>(whole)) <= 0.02;',
                    'state = (scaled - static_cast<double>(whole)) > 0.02;')
            if name=='incorrect_pending_observer':
                assembled=replace_once(assembled,'h.promise().pending=pending;','h.promise().pending=!pending;')
            source.write_text(assembled)
            extras=['-DPEPEW_HOST_HEADER80_FIXTURES','-I',str(dep),str(root/'native/src/core/header_builder.cpp')]+link if name=='header80_fixture_baseline' else []
            subprocess.run(['g++','-std=c++20','-O2','-ffp-contract=off','-fno-fast-math','-Wno-unknown-pragmas',
              '-I',str(root/'native/include'),str(source),'-o',str(binary)]+extras,check=True,timeout=30,capture_output=True,text=True)
            run=subprocess.run([str(binary)],timeout=20,capture_output=True,text=True)
            if error is None:
                if run.returncode:raise RuntimeError('BASELINE_HOST_CHECK_FAILED:'+run.stderr.strip())
                lines=[x for x in run.stdout.splitlines() if x.startswith('HOST_RECONVERGENCE_RESULT ')]
                if len(lines)!=1:raise RuntimeError('MISSING_HOST_RESULT')
                parsed=json.loads(lines[0].split(' ',1)[1])
                if parsed.get('mismatches')!=0 or parsed.get('hashes')!=2520 or parsed.get('batches')!=192:
                    raise RuntimeError('HOST_COVERAGE_CONTRACT')
                if name=='baseline':result=parsed
                else: result['header80_fixture_result']=parsed
            else:
                if run.returncode!=1 or error not in run.stderr:raise RuntimeError('MUTATION_NOT_DETECTED:'+name)
                detected.append({'mutation':name,'detected':True,'reason':error})
    hist=result['full_warp_frontier_histogram']
    nonzero=sum(hist[1:]); pending=sum(i*n for i,n in enumerate(hist))
    result['full_warp_frontier_summary']={'nonzero_frontiers':nonzero,'pending_calls':pending,
        'mean_pending_lanes_nonzero':pending/nonzero if nonzero else None,
        'frontiers_with_1_to_4_pending':sum(hist[1:5]),
        'frontiers_with_16_to_32_pending':sum(hist[16:]),
        'zero_pending_terminal_frontiers':hist[0],'diagnostic_model_only':True}
    if 'header80_fixture_result' in result:
        real=result['header80_fixture_result'];hh=real['full_warp_frontier_histogram'];nn=sum(hh[1:]);pp=sum(i*n for i,n in enumerate(hh))
        real.update(input_kind='production Header80 builder and BLAKE3 benchmark-job fixtures',blake3_version='1.8.5',official_empty_blake3_kat_pass=True,nonce_wire_mix_contract_pass=True,dependency_blobs=BLAKE3_PINS,header_source_blobs=HEADER_PINS,
            full_warp_frontier_summary={'nonzero_frontiers':nn,'pending_calls':pp,'mean_pending_lanes_nonzero':pp/nn if nn else None,'frontiers_with_1_to_4_pending':sum(hh[1:5]),'frontiers_with_16_to_32_pending':sum(hh[16:]),'zero_pending_terminal_frontiers':hh[0],'diagnostic_model_only':True})
    result.update(candidate_source=SOURCE,source_blobs=PINS,mutations=detected,
      actual_cuda_body_extracted=True,oracle_source_extracted=True,actual_cuda_sw_mode3_helper_extracted=True,
      gpu_gate_pass=False,promotion_eligible=False,
      limitations=['CPU libm replaces CUDA/libdevice nonlinear; actual CUDA mode3 SW helper is extracted with a positive-finite host shim for __double2ull_rd',
                   'Coroutines model collective participation; real GPU scheduling, barriers and code generation remain unverified',
                   'Mixer bytes and per-cell traces only; final BLAKE, full Header80 consensus and performance are not measured'])
    print('HOST_RECONVERGENCE_VALIDATION '+json.dumps(result,sort_keys=True))
if __name__=='__main__':
    try:main()
    except Exception as e:
        print('HOST_RECONVERGENCE_BLOCKED '+(str(e) if isinstance(e,RuntimeError) else type(e).__name__))
        raise SystemExit(78)
