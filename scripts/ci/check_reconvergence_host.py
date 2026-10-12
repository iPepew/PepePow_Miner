#!/usr/bin/env python3
"""Pinned CUDA-body coroutine check on CPU. No GPU/codegen/libdevice performance claims."""
import hashlib,json,pathlib,subprocess,tempfile,sys
PINS={
 'native/src/cuda/v1/header80_backend_part02.inc':'01beeeb3e6e1d7b9a0af58c1c8231cde507650ca',
 'native/src/cuda/v1/header80_hotrun8_fusion.inc':'0332314f6b18c86995273020d90484c2b5800a6a',
 'native/src/cuda/v1/header80_hotrun8.inc':'7d10b86bc58b5f75fae4647705c6bf0fcf634444',
 'native/src/crypto/hoohash_reference.cpp':'b71fcfb8775a534db14084f8cd4fcb3277d4fa23',
 'native/include/pepepow/crypto/hoohash_reference.hpp':'c32830fb513f7843c92bff0a8a485f76c06f6c27',
}
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
    body=body.replace('__syncwarp(warp_mask);','co_await SyncAwaiter{warp_mask,0};',1)
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
    root=pathlib.Path(sys.argv[1]).resolve() if len(sys.argv)==2 else pathlib.Path(__file__).resolve().parents[2]
    if len(sys.argv)>2:raise RuntimeError('UNSUPPORTED_ARGUMENTS')
    assemble,body=generate(root)
    mutations=[
      ('missing_second_barrier',replace_once(body,'co_await SyncAwaiter{warp_mask,1};','/* removed second barrier */'),'collective slot order'),
      ('finished_lane_early_exit',replace_once(body,'co_await SyncAwaiter{warp_mask,0};','if (done) co_return;\n        co_await SyncAwaiter{warp_mask,0};'),'early lane completion before cohort'),
      ('skipped_zero_state_update',body.replace('update_sw_state(sw, sum);','if (nibble != 0U) update_sw_state(sw, sum);',1),'per-cell FP64/SW trace mismatch'),
    ]
    mutations.append(('incorrect_sw_mode3_predicate',body,'per-cell FP64/SW trace mismatch'))
    result=None;detected=[]
    with tempfile.TemporaryDirectory(prefix='pepew-host-reconvergence-') as directory:
        work=pathlib.Path(directory)
        for name,candidate,error in [('baseline',body,None)]+mutations:
            source=work/(name+'.cpp');binary=work/name
            assembled=assemble(candidate)
            if name=='incorrect_sw_mode3_predicate':
                assembled=replace_once(assembled,'state = (scaled - static_cast<double>(whole)) <= 0.02;',
                    'state = (scaled - static_cast<double>(whole)) > 0.02;')
            source.write_text(assembled)
            subprocess.run(['g++','-std=c++20','-O2','-ffp-contract=off','-fno-fast-math','-Wno-unknown-pragmas',
              '-I',str(root/'native/include'),str(source),'-o',str(binary)],check=True,timeout=30,capture_output=True,text=True)
            run=subprocess.run([str(binary)],timeout=20,capture_output=True,text=True)
            if name=='baseline':
                if run.returncode:raise RuntimeError('BASELINE_HOST_CHECK_FAILED:'+run.stderr.strip())
                lines=[x for x in run.stdout.splitlines() if x.startswith('HOST_RECONVERGENCE_RESULT ')]
                if len(lines)!=1:raise RuntimeError('MISSING_HOST_RESULT')
                result=json.loads(lines[0].split(' ',1)[1])
                if result.get('mismatches')!=0 or result.get('hashes')!=2520 or result.get('batches')!=192:
                    raise RuntimeError('HOST_COVERAGE_CONTRACT')
            else:
                if run.returncode!=1 or error not in run.stderr:raise RuntimeError('MUTATION_NOT_DETECTED:'+name)
                detected.append({'mutation':name,'detected':True,'reason':error})
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
