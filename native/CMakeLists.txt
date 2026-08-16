cmake_minimum_required(VERSION 3.24)

project(PepePowMiner VERSION 0.1.3 LANGUAGES C CXX)

option(PEPEPOW_ENABLE_CUDA "Build the NVIDIA CUDA backend" OFF)
option(PEPEPOW_BUILD_TESTS "Build unit tests" ON)
option(PEPEPOW_CUDA_PTXAS_VERBOSE "Print ptxas register, stack and spill statistics" OFF)
set(PEPEPOW_CUDA_MAX_REGISTERS "" CACHE STRING "Optional CUDA max registers per thread; empty keeps compiler default")
set(PEPEPOW_CUDA_ARCHITECTURES "70;86" CACHE STRING "CUDA architectures for release builds (Tesla V100 sm_70; RTX 3080 sm_86)")

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(FetchContent)
find_package(Threads REQUIRED)
set(BLAKE3_SIMD_TYPE "none" CACHE STRING "Use portable BLAKE3 for deterministic reference builds" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "Disable dependency tests" FORCE)
FetchContent_Declare(
    blake3_source
    GIT_REPOSITORY https://github.com/BLAKE3-team/BLAKE3.git
    GIT_TAG 1.8.5
    GIT_SHALLOW TRUE
    SOURCE_SUBDIR c
)
FetchContent_Declare(
    nlohmann_json
    GIT_REPOSITORY https://github.com/nlohmann/json.git
    GIT_TAG v3.11.3
    GIT_SHALLOW TRUE
)
FetchContent_MakeAvailable(blake3_source nlohmann_json)

add_library(pepepow_core
    src/core/header_builder.cpp
    src/core/cpu_backend.cpp
    src/crypto/blake3.cpp
    src/crypto/hoohash_reference.cpp
    src/crypto/pow.cpp
    src/mining/target.cpp
    src/network/stratum_client.cpp
)

target_include_directories(pepepow_core PUBLIC include)
target_compile_features(pepepow_core PUBLIC cxx_std_20)
target_link_libraries(pepepow_core PUBLIC BLAKE3::blake3 nlohmann_json::nlohmann_json Threads::Threads)
if(WIN32)
    target_link_libraries(pepepow_core PUBLIC ws2_32)
endif()

if(MSVC)
    target_compile_options(pepepow_core PRIVATE /W4 /permissive-)
else()
    target_compile_options(pepepow_core PRIVATE -Wall -Wextra -Wpedantic -Wconversion)
endif()

if(PEPEPOW_ENABLE_CUDA)
    enable_language(CUDA)
    add_library(pepepow_cuda
        src/cuda/cuda_backend.cu
        src/cuda/header80_backend.cu
        src/cuda/hoohash_matrix_reference.cu
        src/cuda/pow_pipeline_reference.cu
        src/cuda/warp_divergence_probe.cu
    )
    target_include_directories(pepepow_cuda PUBLIC include)
    target_link_libraries(pepepow_cuda PUBLIC pepepow_core)
    # CUDA 11.8 cannot compile CUDA C++20 in this project configuration. The
    # device translation units only require C++17; keep host/core code at C++20.
    set_target_properties(pepepow_cuda PROPERTIES
        CUDA_STANDARD 17
        CUDA_STANDARD_REQUIRED ON
        CUDA_ARCHITECTURES "${PEPEPOW_CUDA_ARCHITECTURES}"
        CUDA_SEPARABLE_COMPILATION OFF
    )
    # HooHashV110 is consensus-sensitive to floating-point behavior. Keep the
    # CUDA path strict: no fused multiply-add, approximate div/sqrt, FTZ or
    # fast-math transformations.
    target_compile_options(pepepow_cuda PRIVATE
        $<$<COMPILE_LANGUAGE:CUDA>:--fmad=false>
        $<$<COMPILE_LANGUAGE:CUDA>:--prec-div=true>
        $<$<COMPILE_LANGUAGE:CUDA>:--prec-sqrt=true>
        $<$<COMPILE_LANGUAGE:CUDA>:--ftz=false>
    )

    if(PEPEPOW_CUDA_PTXAS_VERBOSE)
        target_compile_options(pepepow_cuda PRIVATE
            $<$<COMPILE_LANGUAGE:CUDA>:-Xptxas=-v>
            $<$<COMPILE_LANGUAGE:CUDA>:-lineinfo>
        )
    endif()

    if(NOT PEPEPOW_CUDA_MAX_REGISTERS STREQUAL "")
        if(NOT PEPEPOW_CUDA_MAX_REGISTERS MATCHES "^[0-9]+$")
            message(FATAL_ERROR "PEPEPOW_CUDA_MAX_REGISTERS must be an integer or empty")
        endif()
        target_compile_options(pepepow_cuda PRIVATE
            $<$<COMPILE_LANGUAGE:CUDA>:--maxrregcount=${PEPEPOW_CUDA_MAX_REGISTERS}>
        )
    endif()

    add_executable(pepepow_cuda_benchmark src/benchmark/cuda_benchmark.cpp)
    target_link_libraries(pepepow_cuda_benchmark PRIVATE pepepow_cuda)

    add_executable(pepepow_cuda_warp_probe src/benchmark/warp_divergence_probe.cpp)
    target_link_libraries(pepepow_cuda_warp_probe PRIVATE pepepow_cuda)
endif()

add_executable(pepepowminer src/app/main.cpp)
target_link_libraries(pepepowminer PRIVATE pepepow_core)

if(PEPEPOW_ENABLE_CUDA)
    target_link_libraries(pepepowminer PRIVATE pepepow_cuda)
    target_compile_definitions(pepepowminer PRIVATE PEPEPOW_HAS_CUDA=1)
endif()

if(PEPEPOW_BUILD_TESTS)
    enable_testing()
    add_executable(pepepow_core_tests tests/core_tests.cpp)
    target_link_libraries(pepepow_core_tests PRIVATE pepepow_core)
    add_test(NAME pepepow_core_tests COMMAND pepepow_core_tests)

    if(PEPEPOW_ENABLE_CUDA)
        add_executable(pepepow_cuda_tests tests/cuda_tests.cpp)
        target_link_libraries(pepepow_cuda_tests PRIVATE pepepow_cuda)
        add_test(NAME pepepow_cuda_tests COMMAND pepepow_cuda_tests)

        add_executable(pepepow_cuda_header80_validation tests/cuda_header80_validation.cpp)
        target_link_libraries(pepepow_cuda_header80_validation PRIVATE pepepow_cuda)
        add_test(NAME pepepow_cuda_header80_validation COMMAND pepepow_cuda_header80_validation)
    endif()
endif()
