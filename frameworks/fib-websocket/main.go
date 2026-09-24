package main

import (
	"log"
	"os"
	"os/signal"
	"syscall"

	fib "github.com/lesismal/fib"
	"github.com/lesismal/fib/websocket"
)

// fib's websocket package is a connection handler of its own: it answers the
// upgrade on the engine's connections and then parses frames off the same read
// buffer the event loop filled, so a message is echoed on the worker that read
// it without a goroutine per connection. Anything that is not an upgrade gets
// 400.
func main() {
	handler := websocket.NewHandler(websocket.HandlerFuncs{
		// A message arrives whole, reassembled from its frames, and is valid
		// only during the call; WriteMessage copies it into the send queue.
		Message: func(c *websocket.Connection, opcode websocket.Opcode, data []byte) {
			if err := c.WriteMessage(opcode, data); err != nil {
				c.Close(websocket.CloseInternalError, "write failed")
			}
		},
	})

	config := fib.DefaultConfig()
	config.Addr = ":8080"
	engine, err := fib.Bind(config, handler)
	if err != nil {
		log.Fatalf("fib: bind: %v", err)
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-stop
		engine.Stop()
	}()

	if err := engine.Run(); err != nil {
		log.Fatalf("fib: %v", err)
	}
}
