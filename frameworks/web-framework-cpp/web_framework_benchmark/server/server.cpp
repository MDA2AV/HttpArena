#include <iostream>
#include <cstdlib>

#include <import.hpp>

int main(int argc, char** argv) try
{
	framework::utility::initializeWebFramework();

	framework::utility::Config config("config.json");

	if (const char* ptr = std::getenv("THREADS"))
	{
		if (int value = std::stoi(ptr); value > 8)
		{
			config.overrideConfiguration("threadCount", value - 8);
		}
	}

	if (const char* ptr = std::getenv("H2THREADS"))
	{
		// TODO: HTTP/2.0
	}

	framework::WebFramework server(config);

	server.start(true, []() { std::cout << "Server is running..." << std::endl; });

	return 0;
}
catch (const std::exception& e)
{
	std::cerr << e.what() << std::endl;

	return 1;
}
