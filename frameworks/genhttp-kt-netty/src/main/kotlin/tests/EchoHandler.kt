package genhttp.tests

import org.genhttp.modules.websockets.ImperativeConnection
import org.genhttp.modules.websockets.ImperativeHandler
import org.genhttp.modules.websockets.WebsocketFrame
import org.genhttp.modules.websockets.protocol.FrameType

class EchoHandler : ImperativeHandler {

    override suspend fun handle(connection: ImperativeConnection) {
        while (connection.request.server.running) {
            val frame = connection.readFrame()

            if (!handle(frame, connection)) return

            while (true) {
                val next = connection.tryReadFrame() ?: break

                if (!handle(next, connection)) return
            }

            connection.flush()
        }
    }

    private suspend fun handle(frame: WebsocketFrame, connection: ImperativeConnection): Boolean {
        if (frame.type == FrameType.Close || frame.type == FrameType.Error) {
            return false
        }

        if (frame.type == FrameType.Text || frame.type == FrameType.Binary) {
            connection.write(frame.data, frame.type, flush = false)
        }

        return true
    }

}
