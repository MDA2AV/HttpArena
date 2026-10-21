// /ws: the WEBSOCKET export is handed to uWebSockets.js as is. Every connection goes through the
// real upgrade handshake, and each frame is sent straight back, text or binary.
export default {
  WEBSOCKET: {
    maxPayloadLength: 16 * 1024,
    message: (ws, message, isBinary) => {
      ws.send(message, isBinary)
    }
  }
}
