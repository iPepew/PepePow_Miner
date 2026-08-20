#!/usr/bin/env python3
from pathlib import Path

src = Path("native/src/cuda/header80_backend_cuda118_v2.cu")
text = src.read_text()

old = r'''__device__ __forceinline__ void accumulate_row(
    int row,const std::uint8_t first[32],double hm,double nm,double& sw,double& product){
    #pragma unroll 1
    for(int j=0;j<64;++j){
        const double v=static_cast<double>(nibble(first,j));
        if(sw<=0.02){
            const double x=d_matrix[row][j]*hm*v+nm;
            product+=safe_complex(x)*v*1234.0;
        }else{
            product+=d_matrix[row][j]*0.0001*v;
        }
        sw=product/1024.0-floor(product/1024.0);
    }
}
'''
new = r'''// KV8-A consensus-safe state reduction.
// HooHash consumes sw only through the predicate sw<=0.02. product is always
// non-negative, so floor(product/1024) is exactly equivalent to a round-down
// FP64->uint64 conversion in the reachable range. Keep only that predicate live.
// A zero nibble multiplies both branches by zero and therefore cannot change
// product or the next sw predicate; skipping it is bit-for-bit equivalent.
__device__ __forceinline__ bool sw_low_from_product(double product){
    const double q=product*0x1p-10; // exact binary division by 1024
    const unsigned long long whole=__double2ull_rd(q);
    return (q-static_cast<double>(whole))<=0.02;
}

__device__ __forceinline__ void accumulate_row(
    int row,const std::uint8_t first[32],double hm,double nm,bool& sw_low,double& product){
    #pragma unroll 1
    for(int j=0;j<64;++j){
        const std::uint8_t vi=nibble(first,j);
        if(vi==0U)continue;
        const double v=static_cast<double>(vi);
        if(sw_low){
            const double x=d_matrix[row][j]*hm*v+nm;
            product+=safe_complex(x)*v*1234.0;
        }else{
            product+=d_matrix[row][j]*0.0001*v;
        }
        sw_low=sw_low_from_product(product);
    }
}
'''
if text.count(old) != 1:
    raise SystemExit(f"KV8-A accumulate marker count={text.count(old)}, expected 1")
text = text.replace(old, new)

old_init = "    double sw=0.0;\n"
new_init = "    bool sw_low=true;\n"
if text.count(old_init) != 1:
    raise SystemExit(f"KV8-A sw init count={text.count(old_init)}, expected 1")
text = text.replace(old_init, new_init)

old_calls = "        accumulate_row(pair*2,first,hm,nm,sw,p0);\n        accumulate_row(pair*2+1,first,hm,nm,sw,p1);"
new_calls = "        accumulate_row(pair*2,first,hm,nm,sw_low,p0);\n        accumulate_row(pair*2+1,first,hm,nm,sw_low,p1);"
if text.count(old_calls) != 1:
    raise SystemExit(f"KV8-A call marker count={text.count(old_calls)}, expected 1")
text = text.replace(old_calls, new_calls)

required = [
    "sw_low_from_product",
    "__double2ull_rd(q)",
    "if(vi==0U)continue;",
    "bool sw_low=true;",
]
for marker in required:
    if marker not in text:
        raise SystemExit(f"KV8-A missing marker: {marker}")

if "sw=product/1024.0-floor(product/1024.0);" in text:
    raise SystemExit("KV8-A legacy sw floor update survived")

src.write_text(text)
print("[KV8-A] exact sw predicate + zero-nibble fast path applied")
