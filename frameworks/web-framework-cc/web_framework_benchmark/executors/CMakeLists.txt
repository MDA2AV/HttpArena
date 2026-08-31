cmake_minimum_required(VERSION 4.0.0)

project(executors)

add_library(
	${PROJECT_NAME} SHARED
	src/baseline11.c
	src/echo.c
	src/json_executor.c
	src/pipeline.c
	src/ws.c
)

target_link_libraries(
	${PROJECT_NAME} PRIVATE
	CC_API
)

install(TARGETS ${PROJECT_NAME} DESTINATION .)
install(FILES web.json DESTINATION .)
