#!/usr/bin/env python3
"""Small pinned CPU cohort: compare exact warm2/warm4 frontier masks, not GPU speed."""
import argparse,hashlib,json,pathlib,struct,subprocess,tempfile
import check_reconvergence_host as host
WARM2_BLOB='fb7b38664ced745888714d7618d18a160777dea3'
WARM4_BLOB='109369dbcaf98c08a3f409ba834e2ffee6875af2'
HARNESS_BLOB='46c2db6b2bebb6eb60daf2aaa0505b66bf33ad89'
def blob(data):
    return hashlib.sha1(b'blob '+str(len(data)).encode()+b'\0'+data).hexdigest()
def transform(text):
    body=host.extract(text,'hoohash_mix_words_hotrun8_reconverged')
    body=host.replace_once(body,'__device__ __noinline__ void','Task')
    body=host.replace_once(body,'__activemask()','active_mask')
    if body.count('__syncwarp(warp_mask);')!=2:raise RuntimeError('SOURCE_BARRIERS')
    body=body.replace('__syncwarp(warp_mask);','co_await SyncAwaiter{warp_mask,0,pending};',1)
    body=body.replace('__syncwarp(warp_mask);','co_await SyncAwaiter{warp_mask,1};',1)
    return host.replace_once(body,'__any_sync(warp_mask, !done)','co_await VoteAwaiter{warp_mask,!done}')
def small(assembled):
    replacements=[
      ('static std::uint64_t nonlinear_calls=0;','static std::uint64_t nonlinear_calls=0;\nstatic std::vector<unsigned> frontier_masks, frontier_lengths;'),
      ('unsigned pending=0;','unsigned pending=0, pending_mask=0;'),
      ('for(int lane:lanes) pending+=tasks[lane].h.promise().pending;','for(int lane:lanes) { pending+=tasks[lane].h.promise().pending; if(tasks[lane].h.promise().pending) pending_mask|=1U<<lane; }\n            frontier_masks.push_back(pending_mask);'),
      ('const std::array<unsigned,8> masks{1U,3U,0x1ffffU,0x7fffffffU,0xffffffffU,0x80000001U,0xaaaaaaaaU,0x01010101U};','const std::array<unsigned,1> masks{0xffffffffU};'),
      ('header<8','header<2'),
      ('order<3','order<1'),
      ('dispatch(tasks,mask,order);','const auto frontier_begin=frontier_masks.size();\n                dispatch(tasks,mask,order);\n                frontier_lengths.push_back(frontier_masks.size()-frontier_begin);'),
      ('batches!=192 || hashes!=2520 || cells!=10321920','batches!=2 || hashes!=64 || cells!=262144'),
      ('std::cout<<"]}\\n";','std::cout<<"],\\\"frontier_masks\\\":[";\n        for(unsigned i=0;i<frontier_masks.size();++i) std::cout<<(i?",":"")<<frontier_masks[i];\n        std::cout<<"],\\\"frontier_lengths\\\":[";\n        for(unsigned i=0;i<frontier_lengths.size();++i) std::cout<<(i?",":"")<<frontier_lengths[i];\n        std::cout<<"]}\\n";')
    ]
    for old,new in replacements:assembled=host.replace_once(assembled,old,new)
    return assembled
def main():
    p=argparse.ArgumentParser();p.add_argument('root',type=pathlib.Path);p.add_argument('warm2',type=pathlib.Path);p.add_argument('--blake3-root',required=True,type=pathlib.Path)
    a=p.parse_args();root=a.root.resolve();dep=a.blake3_root.resolve();warm2=a.warm2.read_bytes()
    if blob(warm2)!=WARM2_BLOB or host.PINS['native/src/cuda/v1/header80_hotrun8_fusion.inc']!=WARM4_BLOB:raise RuntimeError('SOURCE_IDENTITY')
    if blob((root/'native/tests/reconvergence_host_harness.inc').read_bytes())!=HARNESS_BLOB:raise RuntimeError('HARNESS_IDENTITY')
    assemble,warm4=host.generate(root)
    for pins,base in ((host.HEADER_PINS,root),(host.BLAKE3_PINS,dep)):
        for path,expected in pins.items():
            if blob((base/path).read_bytes())!=expected:raise RuntimeError('DEPENDENCY_IDENTITY')
    reports={}
    with tempfile.TemporaryDirectory(prefix='pepew-frontier-width-') as directory:
        work=pathlib.Path(directory);link=[]
        for name in ('blake3.c','blake3_portable.c','blake3_dispatch.c'):
            obj=work/(name+'.o')
            subprocess.run(['gcc','-O2','-DBLAKE3_NO_SSE2','-DBLAKE3_NO_SSE41','-DBLAKE3_NO_AVX2','-DBLAKE3_NO_AVX512','-DBLAKE3_USE_NEON=0','-I',str(dep),'-c',str(dep/name),'-o',str(obj)],check=True,timeout=20,capture_output=True,text=True);link.append(str(obj))
        for label,body in [('warm2',transform(warm2.decode())),('warm4',warm4)]:
            src=work/(label+'.cpp');exe=work/label;src.write_text(small(assemble(body)))
            subprocess.run(['g++','-std=c++20','-O2','-ffp-contract=off','-fno-fast-math','-Wno-unknown-pragmas','-DPEPEW_HOST_HEADER80_FIXTURES','-I',str(dep),'-I',str(root/'native/include'),str(src),str(root/'native/src/core/header_builder.cpp'),*link,'-o',str(exe)],check=True,timeout=25,capture_output=True,text=True)
            run=subprocess.run([str(exe)],check=True,timeout=15,capture_output=True,text=True)
            rows=[x for x in run.stdout.splitlines() if x.startswith('HOST_RECONVERGENCE_RESULT ')]
            if len(rows)!=1:raise RuntimeError('RESULT_CONTRACT')
            reports[label]=json.loads(rows[0].split(' ',1)[1])
    x,y=reports['warm2'],reports['warm4']
    keys=['frontier_masks','frontier_lengths','nonlinear_calls','barrier_arrivals','vote_arrivals','finished_lane_vote_arrivals','frontier_histogram']
    if any(x[k]!=y[k] for k in keys):raise RuntimeError('FRONTIER_TRAJECTORY_CHANGED')
    masks=x['frontier_masks'];nonzero=[n for n in masks if n]
    output={'status':'PASS_CPU_FRONTIER_IDENTITY_ONLY','source_blobs':{'warm2':WARM2_BLOB,'warm4':WARM4_BLOB,'harness':HARNESS_BLOB},'headers':2,'hashes_per_variant':64,'total_cell_trace_comparisons':524288,'mismatches':0,'frontier_masks_equal':True,'frontier_lengths':x['frontier_lengths'],'frontier_mask_sequence_sha256':hashlib.sha256(b''.join(struct.pack('<I',n) for n in masks)).hexdigest(),'nonlinear_calls':x['nonlinear_calls'],'mean_pending_lanes_nonzero':sum(n.bit_count() for n in nonzero)/len(nonzero),'barrier_arrivals':x['barrier_arrivals'],'vote_arrivals':x['vote_arrivals'],'gpu_executed':False,'limitations':['CPU libm is not CUDA libdevice','Coroutine cohort is not hardware warp scheduling','No dynamic instruction count, cycle attribution or speed estimate']}
    print('WARM_WIDTH_FRONTIER_RESULT '+json.dumps(output,sort_keys=True))
if __name__=='__main__':main()
