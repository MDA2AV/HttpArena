cmake_minimum_required(VERSION 3.12...3.31)
project(userver_httparena CXX)

set(CMAKE_CXX_STANDARD 23)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_SOURCE_DIR}/cmake")
include(DownloadUserver)

#boost context find problem hack
find_package(Boost CONFIG REQUIRED COMPONENTS context)

find_package(
		userver
		COMPONENTS core #
		postgresql
		chaotic
		QUIET
)
if (NOT userver_FOUND)
	# Tries TRY_DIR first, falls back to downloading userver from GitHub using CPM.
	download_userver(TRY_DIR third_party/userver)
endif ()

userver_setup_environment()

# Common sources
include_directories(src)

add_library(
		${PROJECT_NAME}_objs OBJECT
		src/handlers/baseline11/handler.hpp
		src/handlers/baseline11/handler.cpp
		src/handlers/baseline2/handler.hpp
		src/handlers/baseline2/handler.cpp
		src/handlers/json/handler.hpp
		src/handlers/json/handler.cpp
		src/handlers/plaintext/handler.hpp
		src/handlers/plaintext/handler.cpp
		src/handlers/upload/handler.hpp
		src/handlers/upload/handler.cpp
		src/handlers/async_db/handler.hpp
		src/handlers/async_db/handler.cpp
		src/dataset_provider.hpp
		src/dataset_provider.cpp
		src/middlewares/compression.hpp
		src/middlewares/compression.cpp
		src/middlewares/compression_pipeline_builder.hpp
)
target_link_libraries(
		${PROJECT_NAME}_objs
		PUBLIC userver::core #
		userver::postgresql
)

# Chaotic codegen
file(GLOB_RECURSE SCHEMAS ${CMAKE_CURRENT_SOURCE_DIR}/schemas/*.yaml)
userver_target_generate_chaotic(
    ${PROJECT_NAME}-chgen
    GENERATE_SERIALIZERS
    LAYOUT "/components/schemas/([^/]*)/=userver_httparena::{0}"
    OUTPUT_DIR ${CMAKE_CURRENT_BINARY_DIR}/src
    SCHEMAS ${SCHEMAS}
    RELATIVE_TO ${CMAKE_CURRENT_SOURCE_DIR}
)
target_link_libraries(${PROJECT_NAME}_objs PUBLIC ${PROJECT_NAME}-chgen)

# The Service
add_executable(${PROJECT_NAME} src/main.cpp)
target_link_libraries(${PROJECT_NAME} PRIVATE ${PROJECT_NAME}_objs)
