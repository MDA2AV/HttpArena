cmake_minimum_required(VERSION 3.16)
project(h2o_h2c C)

set(CMAKE_C_STANDARD 11)

add_executable(h2o-h2c-app src/main.c)

target_include_directories(h2o-h2c-app PRIVATE /usr/local/include)
target_link_directories(h2o-h2c-app PRIVATE /usr/local/lib)
target_link_libraries(h2o-h2c-app PRIVATE h2o-evloop ssl crypto cjson pthread m)
