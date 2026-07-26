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
                return None
