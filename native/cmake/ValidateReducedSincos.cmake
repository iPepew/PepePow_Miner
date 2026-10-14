# The inline polynomial is an exact replay of the pinned sm_70 libdevice path.
# Fail closed instead of silently compiling it for an unvalidated reducer or
# another architecture (including forward-compatible PTX/JIT targets).
if(PEPEPOW_CUDA_INLINE_REDUCED_SINCOS)
    if(NOT PEPEPOW_CUDA_DEMAND_SLICED_REDUCER)
        message(FATAL_ERROR
            "PEPEPOW_CUDA_INLINE_REDUCED_SINCOS requires PEPEPOW_CUDA_DEMAND_SLICED_REDUCER=ON")
    endif()
    if(NOT PEPEPOW_CUDA_ARCHITECTURES STREQUAL "70-real")
        message(FATAL_ERROR
            "PEPEPOW_CUDA_INLINE_REDUCED_SINCOS is validated only for PEPEPOW_CUDA_ARCHITECTURES=70-real")
    endif()
endif()
