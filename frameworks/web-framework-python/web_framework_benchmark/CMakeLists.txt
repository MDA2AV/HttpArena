cmake_minimum_required(VERSION 4.0.0)

set(CMAKE_BUILD_TYPE Release)

set(WEB_FRAMEWORK_VERSION 3.4.2)

set(WITH_PYTHON_EXECUTORS ON)
set(WITH_DOTNET_EXECUTORS OFF)
set(BUILD_PYTHON_API ON) 
set(BUILD_CC_API OFF) 
set(BUILD_CXX_API OFF)
set(BUILD_CSHARP_API OFF)

project(web_framework_benchmark)

set(CMAKE_CXX_FLAGS ${CMAKE_CXX_FLAGS})
set(CMAKE_C_FLAGS ${CMAKE_C_FLAGS})

include(FetchContent)

FetchContent_Declare(
	WebFramework
	GIT_REPOSITORY https://github.com/LazyPanda07/WebFramework.git
	GIT_TAG v${WEB_FRAMEWORK_VERSION}
)

FetchContent_MakeAvailable(WebFramework)

add_subdirectory(server)
add_subdirectory(executors)
