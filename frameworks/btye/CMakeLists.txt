cmake_minimum_required(VERSION 3.21)
project(btye_httparena CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(BTYE_DIR "" CACHE PATH "BT-YE source directory")
add_subdirectory(${BTYE_DIR} btye EXCLUDE_FROM_ALL)

btye_generate_cxx(
    TARGET    arena_api
    SPECS_DIR ${CMAKE_CURRENT_SOURCE_DIR}
    OUT_DIR   ${CMAKE_CURRENT_BINARY_DIR}/generated
    SPECS     arena.yaml
)

add_executable(server main.cpp)
target_link_libraries(server PRIVATE arena_api)
