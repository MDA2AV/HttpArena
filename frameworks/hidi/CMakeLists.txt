cmake_minimum_required(VERSION 3.20)
project(hidi_httparena C CXX)

set(HIDI_DIR "" CACHE PATH "hidi source directory")
add_subdirectory(${HIDI_DIR} hidi EXCLUDE_FROM_ALL)

# glaze for /json: header only, so just its headers (its CMake wants 3.31+)
include(${HIDI_DIR}/cmake/get_cpm.cmake)
CPMAddPackage(
  NAME glaze
  GITHUB_REPOSITORY stephenberry/glaze
  GIT_TAG v9.1.0
  GIT_SHALLOW TRUE
  DOWNLOAD_ONLY YES
)

add_executable(server main.cpp)
target_include_directories(server PRIVATE ${glaze_SOURCE_DIR}/include)
target_link_libraries(server PRIVATE hidilib)
set_target_properties(server PROPERTIES CXX_STANDARD 23 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
