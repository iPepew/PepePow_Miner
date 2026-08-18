cmake_minimum_required(VERSION 3.24)

project(PepePowMiner VERSION 0.1.3 LANGUAGES C CXX)

option(PEPEPOW_ENABLE_CUDA "Build the NVIDIA CUDA backend" OFF)
option(PEPEPOW_BUILD_TESTS "Build unit tests" ON)
option(PEPEPOW_CUDA_PTXAS_VERBOSE "Print ptxas register, stack and spill statistics" ON)
set(PEPEPOW_CUDA_MAX_REGISTERS "" CACHE STRING "Optional CUDA max registers per thread; empty keeps compiler default")
set(PEPEPOW_CUDA_ARCHITECTURES "70;86" CACHE STRING "CUDA architectures for release builds (Tesla V100 sm_70; RTX 3080 sm_86)")
set(PEPEPOW_CUDA_THREADS "64" CACHE STRING "CUDA mining threads per block for Kernel-v2 geometry tests")
set(PEPEPOW_CUDA_BLOCKS "800" CACHE STRING "Fixed CUDA mining block count for Kernel-v2 grid-stride tests")

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
    if(NOT PEPEPOW_CUDA_BLOCKS MATCHES "^[0-9]+$")
        message(FATAL_ERROR "PEPEPOW_CUDA_BLOCKS must be an integer")
    endif()
    if(PEPEPOW_CUDA_BLOCKS LESS 1 OR PEPEPOW_CUDA_BLOCKS GREATER 65535)
        message(FATAL_ERROR "PEPEPOW_CUDA_BLOCKS must be between 1 and 65535")
    endif()

    # Kernel-v2 keeps the strict consensus source immutable. At configure time
    # generate an isolated geometry variant: fixed block count plus a grid-stride
    # nonce loop. The HooHash/BLAKE3 arithmetic itself is not reordered or changed.
    set(_pepepow_cuda_source "${CMAKE_CURRENT_SOURCE_DIR}/src/cuda/header80_backend_cuda118_v2.cu")
    file(READ "${_pepepow_cuda_source}" _pepepow_cuda_text)

    set(_pepepow_thread_marker "constexpr unsigned threads=64;")
    string(FIND "${_pepepow_cuda_text}" "${_pepepow_thread_marker}" _pepepow_thread_marker_pos)
    if(_pepepow_thread_marker_pos EQUAL -1)
        message(FATAL_ERROR "Kernel-v2 launch-width marker not found in ${_pepepow_cuda_source}")
    endif()
    string(REPLACE
        "${_pepepow_thread_marker}"
        "constexpr unsigned threads=${PEPEPOW_CUDA_THREADS};"
        _pepepow_cuda_text
        "${_pepepow_cuda_text}"
    )

    set(_pepepow_search_old [=[
__global__ void search_kernel(const std::uint8_t* base,std::uint32_t first,DeviceSearchResult* result,std::size_t count){
    const std::size_t idx=std::size_t(blockIdx.x)*blockDim.x+threadIdx.x;
    if(idx>=count)return;
    const std::uint32_t nonce=first+static_cast<std::uint32_t>(idx);
    std::uint8_t hash[32];
    hash_one<false>(base,nonce,hash,nullptr,nullptr);
    if(!hash_meets_target_be_device(hash))return;
    if(atomicCAS(&result->found,0U,1U)==0U){
        result->nonce=nonce;
        #pragma unroll
        for(int i=0;i<32;++i)result->hash[i]=hash[i];
    }
}
]=])
    set(_pepepow_search_new [=[
__global__ void search_kernel(const std::uint8_t* base,std::uint32_t first,DeviceSearchResult* result,std::size_t count){
    const std::size_t idx0=std::size_t(blockIdx.x)*blockDim.x+threadIdx.x;
    const std::size_t stride=std::size_t(gridDim.x)*blockDim.x;
    for(std::size_t idx=idx0;idx<count;idx+=stride){
        const std::uint32_t nonce=first+static_cast<std::uint32_t>(idx);
        std::uint8_t hash[32];
        hash_one<false>(base,nonce,hash,nullptr,nullptr);
        if(!hash_meets_target_be_device(hash))continue;
        if(atomicCAS(&result->found,0U,1U)==0U){
            result->nonce=nonce;
            #pragma unroll
            for(int i=0;i<32;++i)result->hash[i]=hash[i];
        }
    }
}
]=])
    string(FIND "${_pepepow_cuda_text}" "${_pepepow_search_old}" _pepepow_search_marker_pos)
    if(_pepepow_search_marker_pos EQUAL -1)
        message(FATAL_ERROR "Kernel-v2 search-kernel marker not found in ${_pepepow_cuda_source}")
    endif()
    string(REPLACE
        "${_pepepow_search_old}"
        "${_pepepow_search_new}"
        _pepepow_cuda_text
        "${_pepepow_cuda_text}"
    )

    set(_pepepow_blocks_marker "const unsigned blocks=static_cast<unsigned>((count+threads-1)/threads);")
    string(FIND "${_pepepow_cuda_text}" "${_pepepow_blocks_marker}" _pepepow_blocks_marker_pos)
    if(_pepepow_blocks_marker_pos EQUAL -1)
        message(FATAL_ERROR "Kernel-v2 block-count marker not found in ${_pepepow_cuda_source}")
    endif()
    string(REPLACE
        "${_pepepow_blocks_marker}"
        "constexpr unsigned blocks=${PEPEPOW_CUDA_BLOCKS};"
        _pepepow_cuda_text
        "${_pepepow_cuda_text}"
    )

    set(_pepepow_cuda_generated "${CMAKE_CURRENT_BINARY_DIR}/header80_backend_cuda118_v2_t${PEPEPOW_CUDA_THREADS}_b${PEPEPOW_CUDA_BLOCKS}.cu")
    file(WRITE "${_pepepow_cuda_generated}" "${_pepepow_cuda_text}")
    message(STATUS "PepeW Kernel-v2C geometry: ${PEPEPOW_CUDA_BLOCKS} blocks x ${PEPEPOW_CUDA_THREADS} threads, grid-stride nonce loop")

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
