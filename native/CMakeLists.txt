cmake_minimum_required(VERSION 3.24)

project(PepePowMiner VERSION 0.1.3 LANGUAGES C CXX)

option(PEPEPOW_ENABLE_CUDA "Build the NVIDIA CUDA backend" OFF)
option(PEPEPOW_BUILD_TESTS "Build unit tests" ON)
option(PEPEPOW_CUDA_PTXAS_VERBOSE "Print ptxas register, stack and spill statistics" ON)
set(PEPEPOW_CUDA_MAX_REGISTERS "" CACHE STRING "Optional CUDA max registers per thread; empty keeps compiler default")
set(PEPEPOW_CUDA_ARCHITECTURES "70;86" CACHE STRING "CUDA architectures for release builds (Tesla V100 sm_70; RTX 3080 sm_86)")
set(PEPEPOW_CUDA_THREADS "256" CACHE STRING "CUDA mining threads per block for Kernel-v4 geometry tests")

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

    if(NOT PEPEPOW_CUDA_THREADS MATCHES "^[0-9]+$")
        message(FATAL_ERROR "PEPEPOW_CUDA_THREADS must be an integer")
    endif()
    if(PEPEPOW_CUDA_THREADS LESS 32 OR PEPEPOW_CUDA_THREADS GREATER 1024)
        message(FATAL_ERROR "PEPEPOW_CUDA_THREADS must be between 32 and 1024")
    endif()

    # KV4-A keeps the measured KV3-B strict scalar path and changes only where
    # the 64x64 job matrix lives. Every lane in a warp reads the same matrix
    # element for a given row/column, so the matrix is moved from global memory
    # to CUDA constant memory. The matrix is generated once per job on the host
    # with the existing strict reference code and copied to the device symbol.
    # Hash arithmetic, FP64 flags, target comparison and launch width are kept
    # unchanged so this remains a clean A/B experiment.
    set(_pepepow_cuda_source "${CMAKE_CURRENT_SOURCE_DIR}/src/cuda/header80_backend_cuda118_v2.cu")
    file(READ "${_pepepow_cuda_source}" _pepepow_cuda_text)

    set(_pepepow_include_marker [=[#include "pepepow/core/header_builder.hpp"
]=])
    set(_pepepow_include_replacement [=[#include "pepepow/core/header_builder.hpp"
#include "pepepow/crypto/blake3.hpp"
#include "pepepow/crypto/hoohash_reference.hpp"
]=])
    string(FIND "${_pepepow_cuda_text}" "${_pepepow_include_marker}" _pepepow_include_pos)
    if(_pepepow_include_pos EQUAL -1)
        message(FATAL_ERROR "KV4-A include marker not found")
    endif()
    string(REPLACE
        "${_pepepow_include_marker}"
        "${_pepepow_include_replacement}"
        _pepepow_cuda_text
        "${_pepepow_cuda_text}"
    )

    set(_pepepow_matrix_decl_marker "__device__ double d_matrix[64][64];")
    set(_pepepow_matrix_decl_replacement "__device__ __constant__ double d_matrix[64][64];")
    string(FIND "${_pepepow_cuda_text}" "${_pepepow_matrix_decl_marker}" _pepepow_matrix_decl_pos)
    if(_pepepow_matrix_decl_pos EQUAL -1)
        message(FATAL_ERROR "KV4-A matrix declaration marker not found")
    endif()
    string(REPLACE
        "${_pepepow_matrix_decl_marker}"
        "${_pepepow_matrix_decl_replacement}"
        _pepepow_cuda_text
        "${_pepepow_cuda_text}"
    )

    set(_pepepow_prepare_marker [=[// One invocation per new job: cache the first BLAKE3 CV and generate the
// HooHash matrix from the nonce-zero header exactly as the reference does.
__global__ void prepare_job_kernel(const std::uint8_t* header){
    if(blockIdx.x||threadIdx.x)return;

    std::uint32_t cv[8];
    first_block_cv(header,cv);
    #pragma unroll
    for(int i=0;i<8;++i)d_first_cv[i]=cv[i];

    std::uint32_t b[16],c[16];
    #pragma unroll
    for(int i=0;i<16;++i)b[i]=0;
    b[0]=le32(header+64);
    b[1]=le32(header+68);
    b[2]=le32(header+72);
    b[3]=0U;
    compress(cv,b,16,kChunkEnd|kRoot,c);

    std::uint8_t seed[32];
    #pragma unroll
    for(int i=0;i<8;++i)put_le32(seed+4*i,c[i]);

    Xoshiro s{le64(seed),le64(seed+8),le64(seed+16),le64(seed+24)};
    for(int i=0;i<64;++i)for(int j=0;j<64;++j){
        const std::uint32_t low=static_cast<std::uint32_t>(xnext(s));
        d_matrix[i][j]=static_cast<double>(low)/static_cast<double>(0xffffffffU)*1000000.0;
    }
}
]=])
    set(_pepepow_prepare_replacement [=[// One invocation per new job: cache only the first BLAKE3 CV. KV4-A creates
// the strict HooHash matrix on the host and uploads it to constant memory.
__global__ void prepare_job_kernel(const std::uint8_t* header){
    if(blockIdx.x||threadIdx.x)return;

    std::uint32_t cv[8];
    first_block_cv(header,cv);
    #pragma unroll
    for(int i=0;i<8;++i)d_first_cv[i]=cv[i];
}
]=])
    string(FIND "${_pepepow_cuda_text}" "${_pepepow_prepare_marker}" _pepepow_prepare_pos)
    if(_pepepow_prepare_pos EQUAL -1)
        message(FATAL_ERROR "KV4-A prepare-job marker not found")
    endif()
    string(REPLACE
        "${_pepepow_prepare_marker}"
        "${_pepepow_prepare_replacement}"
        _pepepow_cuda_text
        "${_pepepow_cuda_text}"
    )

    set(_pepepow_host_prepare_marker [=[    auto* device_header=static_cast<std::uint8_t*>(device_header_);
    cuda_check(cudaMemcpy(device_header,header.data(),kHeaderSize,cudaMemcpyHostToDevice),"cudaMemcpy persistent header");
    prepare_job_kernel<<<1,1>>>(device_header);
]=])
    set(_pepepow_host_prepare_replacement [=[    Header80 matrix_header=header;
    matrix_header[76]=0U;
    matrix_header[77]=0U;
    matrix_header[78]=0U;
    matrix_header[79]=0U;
    const auto matrix_seed=crypto::blake3_hash(
        std::span<const std::uint8_t>(matrix_header.data(),matrix_header.size()));
    const auto matrix=crypto::generate_hoohash_matrix(matrix_seed);
    cuda_check(
        cudaMemcpyToSymbol(d_matrix,matrix[0].data(),sizeof(double)*64U*64U),
        "copy strict HooHash matrix to constant memory");

    auto* device_header=static_cast<std::uint8_t*>(device_header_);
    cuda_check(cudaMemcpy(device_header,header.data(),kHeaderSize,cudaMemcpyHostToDevice),"cudaMemcpy persistent header");
    prepare_job_kernel<<<1,1>>>(device_header);
]=])
    string(FIND "${_pepepow_cuda_text}" "${_pepepow_host_prepare_marker}" _pepepow_host_prepare_pos)
    if(_pepepow_host_prepare_pos EQUAL -1)
        message(FATAL_ERROR "KV4-A host prepare marker not found")
    endif()
    string(REPLACE
        "${_pepepow_host_prepare_marker}"
        "${_pepepow_host_prepare_replacement}"
        _pepepow_cuda_text
        "${_pepepow_cuda_text}"
    )

    # Retain the successful KV3-B strict scalar cleanup.
    set(_pepepow_factor_marker [=[    const double one=(x*kTM)/8.0-floor((x*kTM)/8.0);
    const double two=(x*kTM)/4.0-floor((x*kTM)/4.0);]=])
    set(_pepepow_factor_replacement [=[    const double scaled=x*kTM;
    const double q=scaled*0.125;
    const double one=q-floor(q);
    double two=one+one;
    if(two>=1.0)two-=1.0;]=])
    string(FIND "${_pepepow_cuda_text}" "${_pepepow_factor_marker}" _pepepow_factor_pos)
    if(_pepepow_factor_pos EQUAL -1)
        message(FATAL_ERROR "KV4-A transform-factor marker not found")
    endif()
    string(REPLACE
        "${_pepepow_factor_marker}"
        "${_pepepow_factor_replacement}"
        _pepepow_cuda_text
        "${_pepepow_cuda_text}"
    )

    set(_pepepow_safe_marker [=[__device__ __forceinline__ double safe_complex(double input){
    double rounds=1.0;const double value=complex_transform(input);
    while(isnan(value)||isinf(value)){input*=0.1;if(input<=1e-13)return 0.0;rounds+=1.0;}return value*rounds;
}]=])
    set(_pepepow_safe_replacement [=[__device__ __forceinline__ double safe_complex(double input){
    return complex_transform(input);
}]=])
    string(FIND "${_pepepow_cuda_text}" "${_pepepow_safe_marker}" _pepepow_safe_pos)
    if(_pepepow_safe_pos EQUAL -1)
        message(FATAL_ERROR "KV4-A safe_complex marker not found")
    endif()
    string(REPLACE
        "${_pepepow_safe_marker}"
        "${_pepepow_safe_replacement}"
        _pepepow_cuda_text
        "${_pepepow_cuda_text}"
    )

    set(_pepepow_thread_marker "constexpr unsigned threads=64;")
    string(FIND "${_pepepow_cuda_text}" "${_pepepow_thread_marker}" _pepepow_thread_marker_pos)
    if(_pepepow_thread_marker_pos EQUAL -1)
        message(FATAL_ERROR "KV4-A launch-width marker not found in ${_pepepow_cuda_source}")
    endif()
    string(REPLACE
        "${_pepepow_thread_marker}"
        "constexpr unsigned threads=${PEPEPOW_CUDA_THREADS};"
        _pepepow_cuda_text
        "${_pepepow_cuda_text}"
    )

    set(_pepepow_cuda_generated "${CMAKE_CURRENT_BINARY_DIR}/header80_backend_cuda118_kv4a_cmem_t${PEPEPOW_CUDA_THREADS}.cu")
    file(WRITE "${_pepepow_cuda_generated}" "${_pepepow_cuda_text}")
    message(STATUS "PepeW KV4-A strict constant-matrix experiment enabled")
    message(STATUS "PepeW KV4-A launch width: ${PEPEPOW_CUDA_THREADS} threads/block")

    add_library(pepepow_cuda
        "${_pepepow_cuda_generated}"
    )
    target_include_directories(pepepow_cuda PUBLIC include)
    target_link_libraries(pepepow_cuda PUBLIC pepepow_core)
    set_target_properties(pepepow_cuda PROPERTIES
        CUDA_STANDARD 17
        CUDA_STANDARD_REQUIRED ON
        CUDA_ARCHITECTURES "${PEPEPOW_CUDA_ARCHITECTURES}"
        CUDA_SEPARABLE_COMPILATION OFF
    )

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
endif()
