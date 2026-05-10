#pragma once

#include <Executors/StatelessExecutor.hpp>
#include <WebSocket/WebSocketExecutor.hpp>

namespace executor
{
	class Ws : public framework::StatelessExecutor
	{
	public:
		void doGet(framework::HttpRequest& request, framework::HttpResponse& response) override;
	};

	class WebSocketEcho : public framework::WebSocketExecutor
	{
	public:
		std::optional<std::variant<std::string, std::vector<uint8_t>>> onReceive(const framework::WebSocketExecutor::Frame& frame, std::optional<framework::WebSocketExecutor::Frame::Close>& close) override;
	};
}
