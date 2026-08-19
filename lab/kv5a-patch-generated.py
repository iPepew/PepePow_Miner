#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import sys


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"KV5-A patch failed: {label}: expected 1 marker, found {count}")
    return text.replace(old, new, 1)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: kv5a-patch-generated.py <generated-cu>", file=sys.stderr)
        return 2

    path = pathlib.Path(sys.argv[1])
    text = path.read_text()

    text = replace_once(
        text,
        "__device__ __constant__ double d_matrix[64][64];",
        "__device__ double d_matrix[64][64];\n"
        "__device__ __constant__ double d_matrix_scaled[64][64];",
        "matrix storage",
    )

    text = replace_once(
        text,
        "    const auto matrix=crypto::generate_hoohash_matrix(matrix_seed);\n"
        "    cuda_check(\n"
        "        cudaMemcpyToSymbol(d_matrix,matrix[0].data(),sizeof(double)*64U*64U),\n"
        "        \"copy strict HooHash matrix to constant memory\");",
        "    const auto matrix=crypto::generate_hoohash_matrix(matrix_seed);\n"
        "    auto matrix_scaled=matrix;\n"
        "    for(auto& row:matrix_scaled){\n"
        "        for(double& cell:row)cell*=0.0001;\n"
        "    }\n"
        "    cuda_check(\n"
        "        cudaMemcpyToSymbol(d_matrix,matrix[0].data(),sizeof(double)*64U*64U),\n"
        "        \"copy strict HooHash matrix to global symbol\");\n"
        "    cuda_check(\n"
        "        cudaMemcpyToSymbol(d_matrix_scaled,matrix_scaled[0].data(),sizeof(double)*64U*64U),\n"
        "        \"copy pre-scaled HooHash matrix to constant memory\");",
        "host matrix upload",
    )

    text = replace_once(
        text,
        "        const double v=static_cast<double>(nibble(first,j));\n"
        "        if(sw<=0.02){",
        "        const double v=static_cast<double>(nibble(first,j));\n"
        "        if(v==0.0)continue;\n"
        "        if(sw<=0.02){",
        "zero nibble fast path",
    )

    text = replace_once(
        text,
        "            product+=d_matrix[row][j]*0.0001*v;",
        "            product+=d_matrix_scaled[row][j]*v;",
        "pre-scaled simple path",
    )

    path.write_text(text)
    print("[KV5-A] generated CUDA source patched")
    print("[KV5-A] strict matrix: global symbol (slow nonlinear path)")
    print("[KV5-A] pre-scaled matrix: 32 KiB constant symbol (98% simple path target)")
    print("[KV5-A] zero-nibble work elided without changing product/sw")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
