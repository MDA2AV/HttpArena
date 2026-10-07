package main

import (
	"context"
	"log"

	fib "github.com/lesismal/fib"
	"github.com/lesismal/fib/prefork"
	"github.com/lesismal/fib/websocket"
)

// fib's websocket package is a connection handler of its own: it answers the
// upgrade on the engine's connections and then parses frames off the same read
// buffer the event loop filled, so a message is echoed on the loop that read it
// without a goroutine per connection. Anything that is not an upgrade gets 400.
func run(ctx context.Context) error {
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
		return err
	}
	go func() {
		<-ctx.Done()
		engine.Stop()
	}()
	return engine.Run()
}

// fib's prefork serves the entry from a process for every two CPUs, each with
// two Ps and its own event loop, all listening on :8080 through SO_REUSEPORT
// so that the kernel spreads the connections over them, as fiber's
// EnablePrefork does with one P each.
func main() {
	if err := prefork.Run(prefork.Config{}, run); err != nil {
		log.Fatalf("fib: %v", err)
	}
}
