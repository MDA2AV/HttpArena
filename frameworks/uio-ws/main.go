package main

import (
	"log"
	"os"
	"os/signal"
	"runtime"
	"syscall"

	"github.com/urpc/uio"
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
		_ = conn.SendText(message.Payload)
	case uws.BinaryMessage:
		_ = conn.SendBinary(message.Payload)
	}
}

func (echoHandler) OnClose(*uws.Conn, uws.CloseEvent) {}

func main() {
	server := uws.NewServer(echoHandler{})
	// One event loop per CPU: uio's default is four pollers, which leaves the
	// cores of a benchmark host idle. A read round's replies leave coalesced
	// in one sendmsg, and a send the socket refuses is finished by the next
	// write turn without pausing the read.
	server.Events = &uio.Events{Pollers: runtime.NumCPU()}

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
