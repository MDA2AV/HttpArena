package main

import (
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/quic-go/quic-go/http3"
)

// Sum of every integer query parameter.
func baseline2(w http.ResponseWriter, r *http.Request) {
	sum := 0
	for _, values := range r.URL.Query() {
		for _, v := range values {
			if n, err := strconv.Atoi(v); err == nil {
				sum += n
			}
		}
	}
	body := strconv.Itoa(sum)
	h := w.Header()
	h.Set("Content-Type", "text/plain")
	h.Set("Content-Length", strconv.Itoa(len(body)))
	w.Write([]byte(body))
}

const staticDir = "/data/static/"

var mimeTypes = map[string]string{
	".css": "text/css", ".js": "application/javascript", ".html": "text/html",
	".woff2": "font/woff2", ".svg": "image/svg+xml", ".webp": "image/webp",
	".json": "application/json",
}

// Reports whether the Accept-Encoding header allows coding: the token must be
// listed by name, and counts only when its q value is above zero ("br;q=0"
// means the client refuses br).
func acceptsEncoding(header, coding string) bool {
	for header != "" {
		part := header
		if i := strings.IndexByte(header, ','); i >= 0 {
			part, header = header[:i], header[i+1:]
		} else {
			header = ""
		}
		name, params, _ := strings.Cut(part, ";")
		if !strings.EqualFold(strings.TrimSpace(name), coding) {
			continue
		}
		for params != "" {
			var p string
			p, params, _ = strings.Cut(params, ";")
			p = strings.TrimSpace(p)
			if len(p) > 2 && strings.EqualFold(p[:2], "q=") {
				q, err := strconv.ParseFloat(p[2:], 64)
				return err == nil && q > 0
			}
		}
		return true
	}
	return false
}

// Files are read from disk on every request, so a replaced file is served
// with its new bytes at once. When Accept-Encoding allows it, the .br or .gz
// twin that sits next to the original is served instead; those bytes already
// exist, so nothing is compressed here.
func staticFile(w http.ResponseWriter, r *http.Request) {
	name := r.PathValue("filename")
	if name == "" || strings.Contains(name, "/") || strings.Contains(name, "..") {
		http.NotFound(w, r)
		return
	}
	base := staticDir + name
	path, enc := base, ""
	ae := r.Header.Get("Accept-Encoding")
	if acceptsEncoding(ae, "br") {
		if _, err := os.Stat(base + ".br"); err == nil {
			path, enc = base+".br", "br"
		}
	}
	if enc == "" && acceptsEncoding(ae, "gzip") {
		if _, err := os.Stat(base + ".gz"); err == nil {
			path, enc = base+".gz", "gzip"
		}
	}
	data, err := os.ReadFile(path)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	ct := mimeTypes[filepath.Ext(name)]
	if ct == "" {
		ct = "application/octet-stream"
	}
	h := w.Header()
	h.Set("Content-Type", ct)
	if enc != "" {
		h.Set("Content-Encoding", enc)
		h.Set("Vary", "Accept-Encoding")
	}
	h.Set("Content-Length", strconv.Itoa(len(data)))
	w.Write(data)
}

func main() {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /baseline2", baseline2)
	mux.HandleFunc("GET /static/{filename}", staticFile)

	const cert, key = "/certs/server.crt", "/certs/server.key"

	// The harness probes readiness with curl over TCP on 8443, which cannot
	// speak QUIC, so the same mux also answers HTTP/1.1 and HTTP/2 there.
	// It is idle once the benchmark starts.
	go func() {
		tcp := &http.Server{Addr: ":8443", Handler: mux}
		if err := tcp.ListenAndServeTLS(cert, key); err != nil {
			log.Printf("tcp/8443: %v", err)
		}
	}()

	// baseline-h3 and static-h3: quic-go's HTTP/3 server on udp/8443, default
	// configuration.
	h3 := &http3.Server{Addr: ":8443", Handler: mux}
	if err := h3.ListenAndServeTLS(cert, key); err != nil {
		log.Fatalf("udp/8443: %v", err)
	}
}
