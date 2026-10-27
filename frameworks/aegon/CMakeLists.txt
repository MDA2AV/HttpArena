cmake_minimum_required(VERSION 3.25)
project(aegon_arena LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 26)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(CMAKE_CXX_COMPILER_ID MATCHES "GNU|Clang")
    add_compile_options(-O3 -march=native -Wall -Wextra)
endif()

find_package(Aegon REQUIRED)
find_package(glaze REQUIRED)
find_package(Threads REQUIRED)
find_package(Protobuf REQUIRED)

protobuf_generate_cpp(PROTO_SRCS PROTO_HDRS proto/benchmark.proto)

add_executable(aegon-arena main.cpp ${PROTO_SRCS} ${PROTO_HDRS})

target_include_directories(aegon-arena PRIVATE
    ${CMAKE_CURRENT_BINARY_DIR}
    ${CMAKE_CURRENT_BINARY_DIR}/proto
    ${Protobuf_INCLUDE_DIRS}
)

target_link_libraries(aegon-arena PRIVATE
    Aegon::http
    Aegon::core
    Aegon::config
    glaze::glaze
    Threads::Threads
    ${Protobuf_LIBRARIES}
)
