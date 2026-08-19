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
new = r'''// KV6-B: sw is only consumed as the predicate sw<=0.02. Keep that state as a
// boolean and derive it from the exact positive FP64 product using a power-of-two
// scale plus round-down conversion. This removes the materialized floor result
// from the dependency chain. A zero nibble cannot change product or the next
// predicate, so it is skipped completely.
__device__ __forceinline__ bool sw_low_from_product(double product){
    const double q=product*0x1p-10; // exact 1/1024 scaling in binary FP64
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
    raise SystemExit(f"KV6-B accumulate_row marker count={text.count(old)}, expected 1")
text = text.replace(old, new)

old2 = "    double sw=0.0;\n"
new2 = "    bool sw_low=true;\n"
if text.count(old2) != 1:
    raise SystemExit(f"KV6-B sw init marker count={text.count(old2)}, expected 1")
text = text.replace(old2, new2)

old3 = "        accumulate_row(pair*2,first,hm,nm,sw,p0);\n        accumulate_row(pair*2+1,first,hm,nm,sw,p1);"
new3 = "        accumulate_row(pair*2,first,hm,nm,sw_low,p0);\n        accumulate_row(pair*2+1,first,hm,nm,sw_low,p1);"
if text.count(old3) != 1:
    raise SystemExit(f"KV6-B call marker count={text.count(old3)}, expected 1")
text = text.replace(old3, new3)

required = [
    "sw_low_from_product",
    "__double2ull_rd",
    "if(vi==0U)continue;",
    "bool sw_low=true;",
    "accumulate_row(pair*2,first,hm,nm,sw_low,p0);",
]
for marker in required:
    if marker not in text:
        raise SystemExit(f"KV6-B missing marker: {marker}")

if "sw=product/1024.0-floor(product/1024.0);" in text:
    raise SystemExit("KV6-B legacy sw floor update survived")

src.write_text(text)
print("KV6-B FP64 predicate transform applied")
