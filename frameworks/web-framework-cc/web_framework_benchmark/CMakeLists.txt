cmake_minimum_required(VERSION 4.0.0)

set(CMAKE_CXX_STANDARD 23)

set(AS_DEPENDENCY ON)
set(WITH_PYTHON_EXECUTORS OFF)
set(WITH_DOTNET_EXECUTORS OFF)
set(BUILD_CXX_API OFF)
set(BUILD_PYTHON_API OFF)
set(BUILD_CSHARP_API OFF)

set(WEB_FRAMEWORK_VERSION 3.4.2)

project(web_framework_benchmark)

include(FetchContent)

FetchContent_Declare(
	WebFramework
	GIT_REPOSITORY https://github.com/LazyPanda07/WebFramework.git
	GIT_TAG v${WEB_FRAMEWORK_VERSION}
)

FetchContent_MakeAvailable(WebFramework)

add_subdirectory(server)
add_subdirectory(executors)
