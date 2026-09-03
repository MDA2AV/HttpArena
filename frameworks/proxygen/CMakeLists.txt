cmake_minimum_required(VERSION 3.20)

project(httparena-proxygen LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Which server to build. Both HttpArena entries share this source tree:
#   classic -> proxygen::HTTPServer + the mvfst-backed HQServer   (`proxygen`)
#   coro    -> proxygen::coro::HTTPServer                         (`proxygen-coro`)
set(SERVER_TARGET "classic" CACHE STRING "classic or coro")

# Proxygen's exported Fizz package calls find_dependency(Sodium). The official
# builder image keeps that upstream find module with the Proxygen source tree.
list(APPEND CMAKE_MODULE_PATH "/proxygen/build/fbcode_builder/CMake")

# Proxygen's export refers to the historical un-namespaced c-ares target.
# Resolve the installed package and provide the alias expected by that export.
find_package(c-ares CONFIG REQUIRED)
add_library(cares ALIAS c-ares::cares)

find_package(proxygen CONFIG REQUIRED)

if(SERVER_TARGET STREQUAL "coro")
  add_executable(arena-server src/CoroServer.cpp)
  target_link_libraries(
    arena-server
    PRIVATE
      proxygen::proxygen
      proxygen::proxygen_coro
      proxygen::proxygen_coro_server
      proxygen::proxygen_http_coro_filters_compression_filter_factory
      Folly::folly_init_init
      Folly::folly_portability_gflags
  )
elseif(SERVER_TARGET STREQUAL "classic")
  add_executable(arena-server src/ClassicServer.cpp src/ArenaHQServer.cpp)
  target_link_libraries(
    arena-server
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
else()
  message(FATAL_ERROR "SERVER_TARGET must be 'classic' or 'coro', got '${SERVER_TARGET}'")
endif()

target_include_directories(arena-server PRIVATE src)
target_compile_options(arena-server PRIVATE -Wall -Wextra -Wpedantic)
