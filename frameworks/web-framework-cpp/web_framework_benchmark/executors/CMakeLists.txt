cmake_minimum_required(VERSION 4.0.0)

project(executors)

add_library(
	${PROJECT_NAME} SHARED
	src/Baseline11.cpp
	src/Echo.cpp
	src/JsonExecutor.cpp
	src/Pipeline.cpp
	src/Ws.cpp
)

target_include_directories(
	${PROJECT_NAME} PRIVATE
	include
)

target_link_libraries(
	${PROJECT_NAME} PRIVATE
	CXX_API
)

install(TARGETS ${PROJECT_NAME} DESTINATION .)
install(FILES web.json DESTINATION .)
