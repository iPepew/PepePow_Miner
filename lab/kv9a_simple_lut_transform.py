#!/usr/bin/env python3
from pathlib import Path
import sys


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"KV9-A transform failed: {label}: expected 1 marker, found {count}")
    return text.replace(old, new, 1)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: kv9a_simple_lut_transform.py <generated-cu>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    text = path.read_text()

    text = replace_once(
        text,
        "__device__ __constant__ double d_matrix[64][64];",
        "__device__ __constant__ double d_matrix[64][64];\n"
        "// KV9-A: exact common-path lookup. For each matrix cell, cache all\n"
        "// 16 possible nibble results of (matrix*0.0001)*v. The table is built\n"
        "// on the GPU once per job so rounding is identical to the strict path.\n"
        "__device__ double d_simple_lut[64][64][16];",
        "lookup declaration",
    )

    prepare_marker = r'''__global__ void prepare_job_kernel(const std::uint8_t* header){
    if(blockIdx.x||threadIdx.x)return;

    std::uint32_t cv[8];
    first_block_cv(header,cv);
    #pragma unroll
    for(int i=0;i<8;++i)d_first_cv[i]=cv[i];
}
'''
    prepare_replacement = prepare_marker + r'''
__global__ void build_simple_lut_kernel(){
    constexpr unsigned entries=64U*64U*16U;
    const unsigned idx=blockIdx.x*blockDim.x+threadIdx.x;
    if(idx>=entries)return;
    const unsigned v=idx&15U;
    const unsigned cell=idx>>4U;
    const unsigned row=cell>>6U;
    const unsigned col=cell&63U;
    const double scaled=d_matrix[row][col]*0.0001;
    d_simple_lut[row][col][v]=scaled*static_cast<double>(v);
}
'''
    text = replace_once(text, prepare_marker, prepare_replacement, "lookup builder kernel")

    host_marker = r'''    cuda_check(
        cudaMemcpyToSymbol(d_matrix,matrix[0].data(),sizeof(double)*64U*64U),
        "copy strict HooHash matrix to constant memory");

    auto* device_header=static_cast<std::uint8_t*>(device_header_);
'''
    host_replacement = r'''    cuda_check(
        cudaMemcpyToSymbol(d_matrix,matrix[0].data(),sizeof(double)*64U*64U),
        "copy strict HooHash matrix to constant memory");

    // Populate all exact simple-branch products once per new HooHash matrix.
    // 65,536 entries / 256 threads = 256 blocks. This work is job setup only.
    build_simple_lut_kernel<<<256,256>>>();
    cuda_check(cudaGetLastError(),"KV9-A simple LUT build launch");

    auto* device_header=static_cast<std::uint8_t*>(device_header_);
'''
    text = replace_once(text, host_marker, host_replacement, "host lookup build launch")

    simple_marker = "            product+=d_matrix[row][j]*0.0001*v;"
    simple_replacement = "            product+=__ldg(&d_simple_lut[row][j][static_cast<unsigned>(v)]);"
    text = replace_once(text, simple_marker, simple_replacement, "simple branch lookup")

    required = [
        "d_simple_lut[64][64][16]",
        "build_simple_lut_kernel<<<256,256>>>",
        "__ldg(&d_simple_lut[row][j][static_cast<unsigned>(v)])",
        "product+=safe_complex(x)*v*1234.0;",
        "sw=product/1024.0-floor(product/1024.0);",
    ]
    for marker in required:
        if marker not in text:
            raise SystemExit(f"KV9-A missing marker after transform: {marker}")

    # KV9-A deliberately leaves the strict nonlinear branch and sw state alone.
    if "sw_low_from_product" in text or "bool sw_low=true;" in text:
        raise SystemExit("KV9-A must be based on KV4-A, not the rejected KV8-A state path")

    path.write_text(text)
    print("[KV9-A] exact cell×nibble simple-path LUT applied")
    print("[KV9-A] LUT size: 64*64*16*8 = 524288 bytes")
    print("[KV9-A] strict nonlinear FP64 path and sw recurrence unchanged")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
