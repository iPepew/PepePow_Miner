cmake_minimum_required(VERSION 3.24)

file(STRINGS "${CMAKE_CURRENT_SOURCE_DIR}/../VERSION" PEPEPOW_VERSION LIMIT_COUNT 1)
string(STRIP "${PEPEPOW_VERSION}" PEPEPOW_VERSION)
if(PEPEPOW_VERSION STREQUAL "")
    message(FATAL_ERROR "VERSION file is empty")
endif()
project(PepePowMiner VERSION 1.0.4 LANGUAGES C CXX)

option(PEPEPOW_ENABLE_CUDA "Build the NVIDIA CUDA backend" OFF)
option(PEPEPOW_BUILD_TESTS "Build unit tests" ON)
option(PEPEPOW_CUDA_PTXAS_VERBOSE "Print ptxas register, stack and spill statistics" OFF)
set(PEPEPOW_CUDA_ARCHITECTURES "61-real;75-real;86-real;89-real;120" CACHE STRING "CUDA targets for GTX 10, RTX 20, RTX 30, RTX 40 and RTX 50")
set(PEPEPOW_CUDA_MAX_REGISTERS "" CACHE STRING "Optional CUDA max registers per thread; empty keeps compiler default")
set(PEPEPOW_CUDA_THREADS "768" CACHE STRING "CUDA threads per Header80 search block")
set(PEPEPOW_CUDA_MIN_BLOCKS "1" CACHE STRING "Requested resident blocks per SM for launch bounds")
option(PEPEPOW_CUDA_SCALED_MATRIX "Use exact pre-scaled matrix" ON)
option(PEPEPOW_CUDA_SPLIT_PIPELINE "Use split Header80 pipeline" OFF)
option(PEPEPOW_CUDA_HOTRUN8 "Use exact hot-run8 HooHash middle stage" OFF)
option(PEPEPOW_CUDA_FAST_FRACTION "Use exact bit-level positive fraction" ON)
option(PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS "Use exact integer-to-FP64 bit conversion" ON)
option(PEPEPOW_CUDA_BIT_SW_FRACTION "Use exact bit-level SW fraction" ON)
option(PEPEPOW_CUDA_DERIVE_TWO "Derive nonlinear selector two from one" OFF)
option(PEPEPOW_CUDA_NIBBLE_TABLE "Use constant nibble conversion table" OFF)
option(PEPEPOW_CUDA_SCALED_NIBBLE_TABLE "Use device scaled-nibble lookup table" ON)
option(PEPEPOW_CUDA_ASSUME_FINITE "Use finite consensus hot path" ON)
set(PEPEPOW_CUDA_SW_STATE_MODE "3" CACHE STRING "HooHash SW state mode")
set(PEPEPOW_CUDA_BYTE_UNROLL "1" CACHE STRING "HooHash byte-loop unroll factor")

execute_process(COMMAND git rev-parse --short=12 HEAD WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/.." OUTPUT_VARIABLE PEPEPOW_GIT_COMMIT OUTPUT_STRIP_TRAILING_WHITESPACE ERROR_QUIET)
if(PEPEPOW_GIT_COMMIT STREQUAL "")
    set(PEPEPOW_GIT_COMMIT "unknown")
endif()
configure_file("${CMAKE_CURRENT_SOURCE_DIR}/../include/pepepow/version.hpp.in" "${CMAKE_CURRENT_BINARY_DIR}/generated/pepepow/version.hpp" @ONLY)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

include(FetchContent)
find_package(Threads REQUIRED)
set(BLAKE3_SIMD_TYPE "none" CACHE STRING "Use portable BLAKE3 for deterministic reference builds" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "Disable dependency tests" FORCE)
FetchContent_Declare(blake3_source GIT_REPOSITORY https://github.com/BLAKE3-team/BLAKE3.git GIT_TAG 1.8.5 GIT_SHALLOW TRUE SOURCE_SUBDIR c)
FetchContent_Declare(nlohmann_json GIT_REPOSITORY https://github.com/nlohmann/json.git GIT_TAG v3.11.3 GIT_SHALLOW TRUE)
FetchContent_MakeAvailable(blake3_source nlohmann_json)

add_library(pepepow_core
    src/core/header_builder.cpp
    src/core/cpu_backend.cpp
    src/crypto/blake3.cpp
    src/crypto/hoohash_reference.cpp
    src/crypto/pow.cpp
    src/mining/target.cpp
    src/network/stratum_client.cpp)
target_include_directories(pepepow_core PUBLIC include "${CMAKE_CURRENT_BINARY_DIR}/generated")
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
    if(CMAKE_CUDA_COMPILER_VERSION VERSION_LESS 12.8)
        message(FATAL_ERROR "PepeW Miner universal build requires CUDA Toolkit 12.8 or newer")
    endif()
    if(CMAKE_CUDA_COMPILER_VERSION VERSION_GREATER_EQUAL 13.0 AND PEPEPOW_CUDA_ARCHITECTURES MATCHES "(^|;)(61|75)(-|;|$)")
        message(FATAL_ERROR "The universal Pascal/Turing package must be built with CUDA 12.8.x")
    endif()
    if(NOT PEPEPOW_CUDA_THREADS MATCHES "^(64|128|256|288|320|352|384|416|448|480|512|544|576|608|640|672|704|736|768)$")
        message(FATAL_ERROR "PEPEPOW_CUDA_THREADS must be a validated service-warp geometry")
    endif()
    if(NOT PEPEPOW_CUDA_MIN_BLOCKS MATCHES "^[1-9][0-9]*$")
        message(FATAL_ERROR "PEPEPOW_CUDA_MIN_BLOCKS must be a positive integer")
    endif()
    if(NOT PEPEPOW_CUDA_SW_STATE_MODE MATCHES "^[0-3]$")
        message(FATAL_ERROR "PEPEPOW_CUDA_SW_STATE_MODE must be 0, 1, 2 or 3")
    endif()
    if(NOT PEPEPOW_CUDA_BYTE_UNROLL MATCHES "^(1|2|4)$")
        message(FATAL_ERROR "PEPEPOW_CUDA_BYTE_UNROLL must be 1, 2 or 4")
    endif()

    add_library(pepepow_cuda
        src/cuda/cuda_backend.cu
        src/cuda/header80_backend.cu
        src/cuda/hoohash_matrix_reference.cu
        src/cuda/pow_pipeline_reference.cu
        src/cuda/warp_divergence_probe.cu)
    target_include_directories(pepepow_cuda PUBLIC include "${CMAKE_CURRENT_BINARY_DIR}/generated")
    target_link_libraries(pepepow_cuda PUBLIC pepepow_core)
    target_compile_definitions(pepepow_cuda PRIVATE
        PEPEPOW_CUDA_THREADS=${PEPEPOW_CUDA_THREADS}
        PEPEPOW_CUDA_MIN_BLOCKS=${PEPEPOW_CUDA_MIN_BLOCKS}
        PEPEPOW_CUDA_SCALED_MATRIX=$<BOOL:${PEPEPOW_CUDA_SCALED_MATRIX}>
        PEPEPOW_CUDA_SPLIT_PIPELINE=$<BOOL:${PEPEPOW_CUDA_SPLIT_PIPELINE}>
        PEPEPOW_CUDA_HOTRUN8=$<BOOL:${PEPEPOW_CUDA_HOTRUN8}>
        PEPEPOW_CUDA_FAST_FRACTION=$<BOOL:${PEPEPOW_CUDA_FAST_FRACTION}>
        PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS=$<BOOL:${PEPEPOW_CUDA_EXACT_BIT_CONVERSIONS}>
        PEPEPOW_CUDA_BIT_SW_FRACTION=$<BOOL:${PEPEPOW_CUDA_BIT_SW_FRACTION}>
        PEPEPOW_CUDA_DERIVE_TWO=$<BOOL:${PEPEPOW_CUDA_DERIVE_TWO}>
        PEPEPOW_CUDA_NIBBLE_TABLE=$<BOOL:${PEPEPOW_CUDA_NIBBLE_TABLE}>
        PEPEPOW_CUDA_SCALED_NIBBLE_TABLE=$<BOOL:${PEPEPOW_CUDA_SCALED_NIBBLE_TABLE}>
        PEPEPOW_CUDA_ASSUME_FINITE=$<BOOL:${PEPEPOW_CUDA_ASSUME_FINITE}>
        PEPEPOW_CUDA_SW_STATE_MODE=${PEPEPOW_CUDA_SW_STATE_MODE}
        PEPEPOW_CUDA_BYTE_UNROLL=${PEPEPOW_CUDA_BYTE_UNROLL})
    set_target_properties(pepepow_cuda PROPERTIES
        CUDA_STANDARD 20
        CUDA_STANDARD_REQUIRED ON
        CUDA_ARCHITECTURES "${PEPEPOW_CUDA_ARCHITECTURES}"
        CUDA_SEPARABLE_COMPILATION OFF)
    target_compile_options(pepepow_cuda PRIVATE $<$<COMPILE_LANGUAGE:CUDA>:--fmad=false>)
    if(PEPEPOW_CUDA_PTXAS_VERBOSE)
        target_compile_options(pepepow_cuda PRIVATE $<$<COMPILE_LANGUAGE:CUDA>:-Xptxas=-v> $<$<COMPILE_LANGUAGE:CUDA>:-lineinfo>)
    endif()
    if(NOT PEPEPOW_CUDA_MAX_REGISTERS STREQUAL "")
        if(NOT PEPEPOW_CUDA_MAX_REGISTERS MATCHES "^[0-9]+$")
            message(FATAL_ERROR "PEPEPOW_CUDA_MAX_REGISTERS must be an integer or empty")
        endif()
        target_compile_options(pepepow_cuda PRIVATE $<$<COMPILE_LANGUAGE:CUDA>:--maxrregcount=${PEPEPOW_CUDA_MAX_REGISTERS}>)
    endif()
    add_executable(pepepow_cuda_benchmark src/benchmark/cuda_benchmark.cpp)
    target_link_libraries(pepepow_cuda_benchmark PRIVATE pepepow_cuda)
    add_executable(pepepow_header80_benchmark src/benchmark/header80_benchmark.cpp)
    target_link_libraries(pepepow_header80_benchmark PRIVATE pepepow_cuda)
    add_executable(pepepow_header80_differential src/benchmark/header80_differential.cpp)
    target_link_libraries(pepepow_header80_differential PRIVATE pepepow_cuda)
    add_executable(pepepow_cuda_warp_probe src/benchmark/warp_divergence_probe.cpp)
    target_link_libraries(pepepow_cuda_warp_probe PRIVATE pepepow_cuda)
endif()

add_executable(pepepow_hoohash_nonlinear_census src/benchmark/hoohash_nonlinear_census.cpp)
target_link_libraries(pepepow_hoohash_nonlinear_census PRIVATE pepepow_core)
add_executable(pepepow_hoohash_speculative_correlation src/benchmark/hoohash_speculative_correlation.cpp)
target_link_libraries(pepepow_hoohash_speculative_correlation PRIVATE pepepow_core)
add_executable(pepepow_hoohash_warm_transition_census src/benchmark/hoohash_warm_transition_census.cpp)
target_link_libraries(pepepow_hoohash_warm_transition_census PRIVATE pepepow_core)

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
