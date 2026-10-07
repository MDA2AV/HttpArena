package main

import (
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"

	"github.com/gobwas/ws"
	"github.com/linfeip/fnet/fhttp"
	"github.com/linfeip/fnet/websocket"
)

// The upgrade is answered by fhttp on fnet's event loops; afterwards websocket
// takes the connection over and parses frames in the connection's own task, so
// an unfragmented message is echoed straight from the read buffer it arrived
// in, with no goroutine per connection. Replies written while a batch of frames
// is being processed leave in one write.
type echoHandler struct{}

func (echoHandler) OnOpen(*websocket.Conn) {}

func (echoHandler) OnMessage(c *websocket.Conn, op ws.OpCode, data []byte) {
	_ = c.WriteMessage(op, data)
}

func (echoHandler) OnClose(*websocket.Conn, error) {}

func main() {
	mux := http.NewServeMux()
	// A request that is not an upgrade is answered with 400 by Upgrade itself.
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		_ = websocket.Upgrade(w, r, echoHandler{}, websocket.Options{})
	})

	server, err := fhttp.NewServer(":8080", mux, fhttp.Options{})
	if err != nil {
		log.Fatal(err)
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-stop
		_ = server.Close()
	}()

	if err := server.Serve(); err != nil {
		log.Fatal(err)
	}
}
