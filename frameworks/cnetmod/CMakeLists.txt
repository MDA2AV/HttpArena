cmake_minimum_required(VERSION 3.28)

project(cnetmod_httparena LANGUAGES C CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_CXX_SCAN_FOR_MODULES ON)

set(CNETMOD_DEPENDENCY_MODE system CACHE STRING "" FORCE)
set(CNETMOD_ENABLE_ALL_PROTOCOLS OFF CACHE BOOL "" FORCE)
set(CNETMOD_ENABLE_HTTP ON CACHE BOOL "" FORCE)
set(CNETMOD_ENABLE_SSL ON CACHE BOOL "" FORCE)
set(CNETMOD_ENABLE_QUIC ON CACHE BOOL "" FORCE)
set(CNETMOD_ENABLE_BORINGSSL_QUIC ON CACHE BOOL "" FORCE)
set(CNETMOD_ENABLE_WEBSOCKET ON CACHE BOOL "" FORCE)
set(CNETMOD_ENABLE_GRPC ON CACHE BOOL "" FORCE)
set(CNETMOD_ENABLE_ORM OFF CACHE BOOL "" FORCE)
set(CNETMOD_ENABLE_YAML_CONFIGURATION OFF CACHE BOOL "" FORCE)
set(CNETMOD_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(CNETMOD_BUILD_BENCHMARKS OFF CACHE BOOL "" FORCE)
set(CNETMOD_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(CNETMOD_BUILD_C_API OFF CACHE BOOL "" FORCE)
set(CNETMOD_BUILD_PYTHON_BINDINGS OFF CACHE BOOL "" FORCE)
set(CNETMOD_CPU_TARGET x86-64-v3 CACHE STRING "" FORCE)
set(CNETMOD_ENABLE_THIN_LTO ON CACHE BOOL "" FORCE)

set(CNETMOD_SOURCE_DIR "/src/cnetmod" CACHE PATH
    "Path to a cnetmod source checkout")
add_subdirectory("${CNETMOD_SOURCE_DIR}" cnetmod-build EXCLUDE_FROM_ALL)

add_executable(cnetmod-httparena server.cpp)
target_link_libraries(cnetmod-httparena PRIVATE
    cnetmod::grpc cnetmod::websocket)
cnetmod_enable_mimalloc(cnetmod-httparena)

add_executable(cnetmod-httparena-h3
    "${CNETMOD_SOURCE_DIR}/testing/bench/arena_h3_server.cpp")
target_link_libraries(cnetmod-httparena-h3 PRIVATE cnetmod::http)
cnetmod_enable_mimalloc(cnetmod-httparena-h3)

if(CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    foreach(target cnetmod-httparena cnetmod-httparena-h3)
        target_compile_options(${target} PRIVATE
            -O3 -DNDEBUG -march=x86-64-v3 -mprefer-vector-width=128
            -flto=thin)
        target_link_options(${target} PRIVATE -flto=thin)
    endforeach()
endif()
