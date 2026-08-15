cmake_minimum_required(VERSION 3.16)
project(httparena_drogon CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

find_package(Drogon CONFIG REQUIRED)

add_executable(server main.cc)
target_link_libraries(server PRIVATE Drogon::Drogon)
