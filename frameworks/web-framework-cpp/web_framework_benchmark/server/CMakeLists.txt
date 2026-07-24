cmake_minimum_required(VERSION 4.0.0)

project(server)

add_executable(
	${PROJECT_NAME}
	server.cpp
)

target_link_libraries(
	${PROJECT_NAME} PRIVATE
	CXX_API
)

install(TARGETS ${PROJECT_NAME} DESTINATION .)
install(FILES config.json DESTINATION .)
