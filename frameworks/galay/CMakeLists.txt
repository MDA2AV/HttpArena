cmake_minimum_required(VERSION 3.28)
project(galay_httparena LANGUAGES CXX)

find_package(galay CONFIG REQUIRED)

add_executable(server main.cc)
target_compile_features(server PRIVATE cxx_std_23)
target_link_libraries(server PRIVATE galay::http)
