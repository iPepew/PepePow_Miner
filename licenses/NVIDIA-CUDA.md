# NVIDIA CUDA components

PepeW source licensing does not relicense NVIDIA components. Their use and
distribution remain governed by NVIDIA's CUDA agreement and applicable notices:
https://docs.nvidia.com/cuda/archive/12.8.1/eula/index.html

Checked 2026-10-17. Attachment A lists Linux libcudart.so, libcudart_static.a,
libcudadevrt.a and libdevice.10.bc as distributable components. Distribution is
conditional on the agreement, including application functionality beyond the
SDK, consistent distribution terms and preservation of NVIDIA rights. This
notice is not a replacement for that agreement or an assertion of NVIDIA
endorsement. Separate component terms can also apply.

Build evidence for run 38906725960 / job 116992041207:
- Image: nvidia/cuda:12.8.1-devel-ubuntu22.04.
- Pulled digest: sha256:a99a1860ba8e2916e5c3e73b72ec4c4301653a84586e05bfc9a2aa2d58027e97.
- Container environment declares NV_CUDA_CUDART_VERSION=12.8.90-1 and
  NV_CUDA_CUDART_DEV_VERSION=12.8.90-1.
- CMake identifies NVIDIA CUDA compiler 12.8.93, GNU host compiler 11.4.0.

The ELF audit detects defined CUDA runtime symbols in ten of the twelve packaged
executables; the two CPU-only test programs do not define the inspected symbols.
Container declarations are provenance evidence, not an exhaustive link inventory.
The existing artifact omitted link command records and dependency notices from
the build environment. Full linked-component verification remains open.

No driver library, CUDA toolkit executable or third-party miner binary is added
as a standalone component. This file is prepared for the next package; the
already hashed preparation.2 archive is unchanged.
