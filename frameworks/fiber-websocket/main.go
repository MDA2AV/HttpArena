package main

import (
	"errors"
	"io"
	"log"

	"github.com/gofiber/contrib/v3/websocket"
	"github.com/gofiber/fiber/v3"
)

// Starting size of the per-connection buffer; it doubles for anything larger.
const echoBuffer = 1024

// Ceiling on one message, enforced by SetReadLimit. The buffer follows the
// largest message a peer sends, up to one doubling past this.
const maxMessage = 1 << 20

// ReadMessage would allocate a 512-byte payload per message (io.ReadAll under
// the hood); NextReader into a per-connection buffer leaves the 8-byte reader.
func echo(c *websocket.Conn) {
	// The middleware closes the socket only when the handler panics, and
	// KeepHijackedConns stops fasthttp from closing it either.
	defer c.Close()

	c.SetReadLimit(maxMessage)
	buf := make([]byte, echoBuffer)
	for {
		mt, r, err := c.NextReader()
		if err != nil {
			return
		}
		n := 0
		for {
			if n == len(buf) {
				buf = append(buf, make([]byte, len(buf))...)
			}
			read, err := r.Read(buf[n:])
			n += read
			if err != nil {
				if errors.Is(err, io.EOF) {
					break
				}
				return
			}
		}
		if err := c.WriteMessage(mt, buf[:n]); err != nil {
			return
		}
	}
}

func main() {
	app := fiber.New()
	app.Get("/ws", websocket.New(echo))

	// One prefork child per CPU the container is given, sharing the port through
	// SO_REUSEPORT; prefork drops each child to GOMAXPROCS(1), one runtime per child.
	if err := app.Listen(":8080", fiber.ListenConfig{
		DisableStartupMessage: true,
		EnablePrefork:         true,
	}); err != nil {
		log.Fatal(err)
	}
}
