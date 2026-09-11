cmake_minimum_required(VERSION 3.28)
project(httparena_cutelyst CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_AUTOMOC ON)
set(CMAKE_INCLUDE_CURRENT_DIR ON)

find_package(Qt6 6.5 REQUIRED COMPONENTS Core Network)
find_package(Cutelyst5Qt6 5.1.0 REQUIRED)

add_executable(server
  main.cpp
  app.cpp
  app.h
  root.cpp
  root.h
)

target_link_libraries(server PRIVATE
  Qt6::Core
  Qt6::Network
  Cutelyst::Core
  Cutelyst::Server
)
