package main

import (
	"log"
	"os"
	"os/signal"
	"syscall"

	"github.com/urpc/uio/uws"
)

// uws answers the RFC 6455 upgrade on uio's connections and parses frames in
// the connection's own I/O task over an edge-triggered loop, so a message is
// echoed by the task that read it, with no goroutine per connection. Anything
// that is not an upgrade is answered with 400 by the server itself.
type echoHandler struct{}

func (echoHandler) OnOpen(*uws.Conn) {}

func (echoHandler) OnMessage(conn *uws.Conn, message uws.Message) {
	switch message.Type {
	case uws.TextMessage:
		_ = conn.SendText(message.Text())
	case uws.BinaryMessage:
		_ = conn.SendBinary(message.Bytes())
	}
}

func (echoHandler) OnClose(*uws.Conn, uws.CloseEvent) {}

func main() {
	// uio's default pollers: one loop per four Ps, at most eight. More loops
	// only add turn hand-offs, which short-lived connections pay repeatedly.
	server := uws.NewServer(uws.Options{
		Handler: echoHandler{},
		// One listening socket per poller, spread by the kernel's SO_REUSEPORT
		// hash: upgrades arrive on the same socket their connection's loop
		// accepts from, which short-lived connections — every upgrade here is
		// one — feel as one less cross-loop handoff.
		ReusePort: true,
	})

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-stop
		_ = server.Close(nil)
	}()

	if err := server.Serve(":8080"); err != nil {
		log.Fatal(err)
	}
}
