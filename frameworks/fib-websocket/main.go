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
// buffer the event loop filled, so a message is echoed on the loop that read it
// without a goroutine per connection. Anything that is not an upgrade gets 400.
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
	// fib's default spreads the connections over one event loop per CPU
	// (IOPollers), each running the rounds of the connections it owns itself.
	// ReusePort has each loop accept its own connections too, on a socket of
	// its own bound to :8080 with SO_REUSEPORT, instead of the engine's loop
	// accepting every connection and waking the loop it hands it to.
	// echo-ws-limited reconnects after every ten messages, and that one
	// accepting loop held it near 95k connections/s, on 35 of the 64 CPUs.
	config.ReusePort = true
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
