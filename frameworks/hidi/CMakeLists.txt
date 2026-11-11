cmake_minimum_required(VERSION 3.20)
project(hidi_httparena C CXX)

set(HIDI_DIR "" CACHE PATH "hidi source directory")
add_subdirectory(${HIDI_DIR} hidi EXCLUDE_FROM_ALL)

add_executable(server main.cpp)
target_link_libraries(server PRIVATE hidilib)
set_target_properties(server PROPERTIES CXX_STANDARD 20 CXX_STANDARD_REQUIRED ON CXX_EXTENSIONS OFF)
