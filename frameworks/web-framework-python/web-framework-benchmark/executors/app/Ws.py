# #include "Ws.hpp"
#
# namespace executor
# {
# 	void Ws::doGet(framework::HttpRequest& request, framework::HttpResponse& response)
# 	{
# 		response.setResponseCode(framework::ResponseCodes::badRequest);
# 	}
#
# 	std::optional<std::variant<std::string, std::vector<uint8_t>>> WebSocketEcho::onReceive(const framework::WebSocketExecutor::Frame& frame, std::optional<framework::WebSocketExecutor::Frame::Close>& close)
# 	{
# 		switch (frame.getType())
# 		{
# 		case framework::WebSocketExecutor::Frame::Type::text:
# 			return std::string(frame.getPayload());
#
# 		case framework::WebSocketExecutor::Frame::Type::binary:
# 		{
# 			std::span<uint8_t> payload = frame.getPayload<std::span<uint8_t>>();
#
# 			return std::vector<uint8_t>(payload.begin(), payload.end());
# 		}
#
# 		case framework::WebSocketExecutor::Frame::Type::close:
# 			close.emplace(framework::WebSocketExecutor::Frame::Close::Code::normalClosure, "validate done");
#
# 			return std::nullopt;
#
# 		default:
# 			break;
# 		}
#
# 		return std::nullopt;
# 	}
#
# 	DEFINE_EXECUTOR(Ws);
# 	DEFINE_WEB_SOCKET_EXECUTOR(WebSocketEcho);
# }

from web_framework_api import StatelessExecutor, WebSocketExecutor, ResponseCodes, Frame


class Ws(StatelessExecutor):
    def do_get(self, request, response):
        response.set_response_code(ResponseCodes.BAD_REQUEST)


class WebSocketEcho(WebSocketExecutor):
    def on_receive(self, frame):
        frame_type = frame.get_type()

        match frame_type:
            case Frame.FrameType.TEXT:
                return frame.get_payload_as_str()
            case Frame.FrameType.BINARY:
                return frame.get_payload_as_bytes()
            case Frame.FrameType.CLOSE:
                return Frame.Close(Frame.Close.NORMAL_CLOSURE, "validate done")
            case _:
                raise Exception(f"Wrong frame type: {frame_type.name}")
