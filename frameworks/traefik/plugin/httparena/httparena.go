// Package traefik_httparena is a Traefik local plugin implementing the
// HttpArena server contract (/baseline11 + /static/*). It is loaded by
// Traefik's Yaegi interpreter at runtime, so everything here sticks to
// the standard library — third-party packages tend to break under Yaegi.
//
// Contract recap:
//   - GET|POST /baseline11?a=X&b=Y — sum query ints (plus POST body as int),
//     reply text/plain with decimal sum, no trailing newline.
//   - GET /static/<path> — serve file at /data/static/<path>.
//   - Anything else falls through to next.ServeHTTP (Traefik will 404 when
//     no backend service matches).
//
// The underscore in the package name is required because Traefik's plugin
// loader derives the package from the last path segment of moduleName
// (`traefik-httparena`) and then sanitises hyphens to underscores.
package traefik_httparena

import (
	"bytes"
	"context"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// Config holds the plugin configuration. No tunables — the plugin is a
// drop-in request handler.
type Config struct{}

// CreateConfig returns the zero-value config. Traefik calls this to
// allocate the struct it then fills from the dynamic config.
func CreateConfig() *Config {
	return &Config{}
}

// HttpArena is the middleware instance Traefik drives per-request.
type HttpArena struct {
	next     http.Handler
	name     string
	staticFS string
}

// maxBodyBytes caps the POST body we'll read — the contract is a single
// integer so anything past a few bytes is noise. 64 KB is generous.
const maxBodyBytes = 64 * 1024

// New wires the middleware into Traefik's handler chain. It's invoked
// once per middleware instance (not per request).
func New(ctx context.Context, next http.Handler, config *Config, name string) (http.Handler, error) {
	return &HttpArena{
		next:     next,
		name:     name,
		staticFS: "/data/static",
	}, nil
}

// ServeHTTP dispatches /baseline11, /pipeline, and /static/* directly and
// delegates everything else to `next`.
func (h *HttpArena) ServeHTTP(rw http.ResponseWriter, req *http.Request) {
	path := req.URL.Path

	if path == "/baseline11" {
		h.handleBaseline(rw, req)
		return
	}

	// Pipelined profile: fixed "ok" body. Cheaper than routing through
	// handleBaseline since there's nothing to parse.
	if path == "/pipeline" {
		rw.Header().Set("Content-Type", "text/plain")
		rw.Header().Set("Content-Length", "2")
		rw.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(rw, "ok")
		return
	}

	if strings.HasPrefix(path, "/static/") {
		h.handleStatic(rw, req, path[len("/static/"):])
		return
	}

	h.next.ServeHTTP(rw, req)
}

// handleBaseline sums query ints and (for POST) the body, replying with
// the decimal sum as text/plain, no trailing newline.
func (h *HttpArena) handleBaseline(rw http.ResponseWriter, req *http.Request) {
	if req.Method != http.MethodGet && req.Method != http.MethodPost {
		rw.Header().Set("Content-Type", "text/plain")
		rw.WriteHeader(http.StatusMethodNotAllowed)
		_, _ = io.WriteString(rw, "Method Not Allowed")
		return
	}

	var sum int64
	for _, values := range req.URL.Query() {
		for _, v := range values {
			n, err := strconv.ParseInt(v, 10, 64)
			if err != nil {
				continue
			}
			sum += n
		}
	}

	if req.Method == http.MethodPost && req.Body != nil {
		body, err := io.ReadAll(io.LimitReader(req.Body, maxBodyBytes))
		if err == nil && len(body) > 0 {
			n, err := strconv.ParseInt(string(bytes.TrimSpace(body)), 10, 64)
			if err == nil {
				sum += n
			}
		}
	}

	out := strconv.FormatInt(sum, 10)
	rw.Header().Set("Content-Type", "text/plain")
	rw.Header().Set("Content-Length", strconv.Itoa(len(out)))
	rw.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(rw, out)
}

// handleStatic serves a file from the /data/static mount. The `rel` arg
// is the path segment after /static/. We reject paths that try to climb
// out of the mount via ../ before joining.
func (h *HttpArena) handleStatic(rw http.ResponseWriter, req *http.Request, rel string) {
	if rel == "" || strings.Contains(rel, "..") {
		http.NotFound(rw, req)
		return
	}

	full := filepath.Join(h.staticFS, filepath.FromSlash(rel))
	// Extra belt-and-braces: after Join, ensure the result is still under
	// the mount prefix.
	if !strings.HasPrefix(full, h.staticFS+string(filepath.Separator)) && full != h.staticFS {
		http.NotFound(rw, req)
		return
	}

	f, err := os.Open(full)
	if err != nil {
		if os.IsNotExist(err) {
			http.NotFound(rw, req)
			return
		}
		http.Error(rw, "internal error", http.StatusInternalServerError)
		return
	}
	defer f.Close()

	info, err := f.Stat()
	if err != nil || info.IsDir() {
		http.NotFound(rw, req)
		return
	}

	rw.Header().Set("Content-Type", contentTypeFor(rel))
	rw.Header().Set("Content-Length", strconv.FormatInt(info.Size(), 10))
	rw.WriteHeader(http.StatusOK)
	_, _ = io.Copy(rw, f)
}

// contentTypeFor returns a content-type for common benchmark assets.
// mime.TypeByExtension would normally cover this, but Yaegi's coverage of
// the `mime` package has historically been patchy, so a tiny hand-rolled
// switch is safer and avoids pulling the extra dependency.
func contentTypeFor(name string) string {
	ext := strings.ToLower(filepath.Ext(name))
	switch ext {
	case ".html", ".htm":
		return "text/html; charset=utf-8"
	case ".css":
		return "text/css; charset=utf-8"
	case ".js", ".mjs":
		return "application/javascript; charset=utf-8"
	case ".json":
		return "application/json"
	case ".txt":
		return "text/plain; charset=utf-8"
	case ".svg":
		return "image/svg+xml"
	case ".png":
		return "image/png"
	case ".jpg", ".jpeg":
		return "image/jpeg"
	case ".gif":
		return "image/gif"
	case ".webp":
		return "image/webp"
	case ".ico":
		return "image/x-icon"
	case ".woff":
		return "font/woff"
	case ".woff2":
		return "font/woff2"
	case ".wasm":
		return "application/wasm"
	case ".br":
		return "application/octet-stream"
	case ".gz":
		return "application/gzip"
	}
	return "application/octet-stream"
}
