cmake_minimum_required(
  VERSION 3.20
)

project(
  doba_httparena_http_v11
  LANGUAGES CXX
)

set(
  CMAKE_CXX_STANDARD
  20
)
set(
  CMAKE_CXX_STANDARD_REQUIRED
  ON
)

set(
  DOBA_INCLUDE_DIR
  "${CMAKE_CURRENT_LIST_DIR}/../../../../include"
  CACHE PATH "Path to the doba include directory"
)

find_package(
  Threads
  REQUIRED
)

# Standalone and Docker builds default to all profiles.
# Root builds default to TCP only; enable full mode for JSON and TLS checks.
set(_httparena_full_default ON)
if(TARGET doba_headers)
  set(_httparena_full_default OFF)
endif()
option(DOBA_HTTPARENA_FULL
  "Build all HttpArena profiles, including JSON and TLS"
  ${_httparena_full_default})
if(DOBA_HTTPARENA_FULL)
  find_package(OpenSSL 3.0 REQUIRED COMPONENTS SSL Crypto)
  find_package(ZLIB REQUIRED)
  find_path(RAPIDJSON_INCLUDE_DIR rapidjson/document.h REQUIRED)
endif()

add_executable(
  doba_httparena_http_v11
  "${CMAKE_CURRENT_LIST_DIR}/main.cpp"
)

target_include_directories(
  doba_httparena_http_v11
  PRIVATE
  "${DOBA_INCLUDE_DIR}"
)

target_link_libraries(
  doba_httparena_http_v11
  PRIVATE
  Threads::Threads
)
if(DOBA_HTTPARENA_FULL)
  target_include_directories(doba_httparena_http_v11 PRIVATE
    "${RAPIDJSON_INCLUDE_DIR}")
  target_link_libraries(doba_httparena_http_v11 PRIVATE OpenSSL::SSL
    OpenSSL::Crypto ZLIB::ZLIB)
  target_compile_definitions(doba_httparena_http_v11 PRIVATE DOBA_ENABLE_TLS=1
    DOBA_HTTPARENA_FULL=1)
else()
  target_compile_definitions(doba_httparena_http_v11 PRIVATE
    DOBA_HTTPARENA_FULL=0)
endif()

source_group(
  TREE "${CMAKE_CURRENT_LIST_DIR}"
  FILES "${CMAKE_CURRENT_LIST_DIR}/main.cpp"
)

# Root builds share doba's compiler warnings and register functional checks.
# Full mode adds TLS to this target only.
if(TARGET doba_headers)
  target_link_libraries(doba_httparena_http_v11 PRIVATE doba_headers)
endif()
if(DOBA_BUILD_TESTS AND BUILD_TESTING AND TARGET doba_native_tools)
  set(_checks_source
    "../../../../tests/integration/benchmarks/httparena.cpp")
  add_executable(doba_httparena_checks
    "${CMAKE_CURRENT_LIST_DIR}/${_checks_source}")
  target_link_libraries(doba_httparena_checks PRIVATE doba_native_tools)
  add_dependencies(doba_httparena_checks doba_httparena_http_v11)
  if(WIN32)
    target_link_libraries(doba_httparena_checks PRIVATE ws2_32)
  endif()
  set(_httparena_test_args)
  if(NOT DOBA_HTTPARENA_FULL)
    list(APPEND _httparena_test_args --plain)
  endif()
  add_test(NAME doba_httparena_tests COMMAND doba_httparena_checks
    "$<TARGET_FILE:doba_httparena_http_v11>"
      "${CMAKE_CURRENT_LIST_DIR}/meta.json" ${_httparena_test_args})
  set_tests_properties(doba_httparena_tests PROPERTIES TIMEOUT 90)
endif()
