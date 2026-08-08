cmake_minimum_required(VERSION 3.20)

project(httparena-proxygen LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Proxygen's exported Fizz package calls find_dependency(Sodium). The official
# builder image keeps that upstream find module with the Proxygen source tree.
list(APPEND CMAKE_MODULE_PATH "/proxygen/build/fbcode_builder/CMake")

# Proxygen's export refers to the historical un-namespaced c-ares target.
# Resolve the installed package and provide the alias expected by that export.
find_package(c-ares CONFIG REQUIRED)
add_library(cares ALIAS c-ares::cares)

find_package(proxygen CONFIG REQUIRED)

add_executable(proxygen-arena ArenaHttpServer.cpp ArenaHQServer.cpp)
target_compile_options(proxygen-arena PRIVATE -Wall -Wextra -Wpedantic)
target_link_libraries(
  proxygen-arena
  PRIVATE
    proxygen::proxygen
    proxygen::proxygenhttpserver
    proxygen::proxygen_hq_samples
    proxygen::proxygen_hq_server
    proxygen::proxygen_transport_persistent_quic_psk_cache
    proxygen::proxygen_httpserver
    Folly::folly_init_init
    Folly::folly_portability_gflags
)
