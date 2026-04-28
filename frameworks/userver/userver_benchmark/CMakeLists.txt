cmake_minimum_required(VERSION 3.12)
project(userver_httparena CXX)

set(CMAKE_CXX_STANDARD 20)

file(GLOB_RECURSE SOURCES
  ${CMAKE_CURRENT_SOURCE_DIR}/controllers/*.cpp
  ${CMAKE_CURRENT_SOURCE_DIR}/common/*.cpp
)

include(GNUInstallDirs)

add_subdirectory(userver)
userver_setup_environment()

add_executable(${PROJECT_NAME} ${SOURCES} userver_httparena.cpp)
target_link_libraries(${PROJECT_NAME} PRIVATE userver-core userver-postgresql userver-llhttp)
