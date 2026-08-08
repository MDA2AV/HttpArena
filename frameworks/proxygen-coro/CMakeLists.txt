cmake_minimum_required(VERSION 3.20)

project(httparena-proxygen-coro LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Proxygen's exported Fizz package calls find_dependency(Sodium). The official
# builder image keeps that upstream find module with the Proxygen source tree.
list(APPEND CMAKE_MODULE_PATH "/proxygen/build/fbcode_builder/CMake")

find_package(c-ares CONFIG REQUIRED)
add_library(cares ALIAS c-ares::cares)
find_package(proxygen CONFIG REQUIRED)

add_executable(proxygen-arena-coro ArenaCoroServer.cpp)
target_compile_options(proxygen-arena-coro PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(
  proxygen-arena-coro
  PRIVATE
    proxygen::proxygen
    proxygen::proxygen_coro
    proxygen::proxygen_coro_server
    proxygen::proxygen_http_coro_filters_compression_filter_factory
    Folly::folly_init_init
    Folly::folly_portability_gflags
)
