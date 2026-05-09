cmake_minimum_required(VERSION 4.0.0)

set(WEB_FRAMEWORK_VERSION 3.4.1)

project(web_framework_benchmark)

include(FetchContent)

FetchContent_Declare(
	WebFramework
	GIT_REPOSITORY https://github.com/LazyPanda07/WebFramework
	GIT_TAG dev
)

FetchContent_MakeAvailable(WebFramework)

execute_process(
	COMMAND cmake -DCMAKE_CXX_FLAGS=${CMAKE_CXX_FLAGS} -DCMAKE_C_FLAGS=${CMAKE_C_FLAGS} -DWITH_PYTHON_EXECUTORS=ON -DWITH_DOTNET_EXECUTORS=OFF -DBUILD_PYTHON_API=ON -DBUILD_CC_API=OFF -DBUILD_CXX_API=OFF -DBUILD_CSHARP_API=OFF -DCMAKE_INSTALL_PREFIX=${CMAKE_INSTALL_PREFIX}/WebFramework -G "Ninja" .
	WORKING_DIRECTORY ${webframework_SOURCE_DIR}
)

execute_process(
	COMMAND cmake --build . -j
	WORKING_DIRECTORY ${webframework_SOURCE_DIR}
)

execute_process(
	COMMAND cmake --install .
	WORKING_DIRECTORY ${webframework_SOURCE_DIR}
)

add_subdirectory(server)
add_subdirectory(executors)
