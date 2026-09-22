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

add_executable(aegon-arena main.cpp)

target_link_libraries(aegon-arena PRIVATE
    Aegon::http
    Aegon::core
    Aegon::config
    glaze::glaze
    Threads::Threads
)
