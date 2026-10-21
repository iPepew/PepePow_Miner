# NVIDIA CUDA components

NVIDIA components remain governed by NVIDIA's CUDA agreement and notices:
https://docs.nvidia.com/cuda/archive/12.8.1/eula/index.html
PepeW's MIT license does not relicense them. No NVIDIA endorsement is implied.
Attachment A lists libcudart_static.a and libcudadevrt.a as distributable,
subject to the agreement's conditions. This notice does not replace those terms.

Build39208192790 link-commands.txt records -lcudadevrt -lcudart_static;
compiler CUDA12.8.93. Container nvidia/cuda:12.8.1-devel-ubuntu22.04,
digest sha256:a99a1860ba8e2916e5c3e73b72ec4c4301653a84586e05bfc9a2aa2d58027e97.
Build records remain in artifact12167075092. Only the unchanged miner executable
is included; CUDA tools, driver libraries and standalone SDK libraries are not.
