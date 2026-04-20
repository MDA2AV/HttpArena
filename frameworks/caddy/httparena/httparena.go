// Package httparena provides a Caddy HTTP handler module implementing the
// HttpArena /baseline11 contract: sum integer query parameters (and, for
// POST, the request body parsed as an integer), respond with the decimal
// sum as text/plain, no trailing newline.
//
// This is Caddy's native extension surface — the Go equivalent of nginx's
// C modules or h2o's mruby handlers — compiled into the caddy binary via
// xcaddy at build time.
package httparena

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"strconv"

	"github.com/caddyserver/caddy/v2"
	"github.com/caddyserver/caddy/v2/caddyconfig/caddyfile"
	"github.com/caddyserver/caddy/v2/caddyconfig/httpcaddyfile"
	"github.com/caddyserver/caddy/v2/modules/caddyhttp"
)

// maxBodyBytes caps the POST body we'll read. The contract only asks for a
// single integer so anything past a few bytes is noise; 64 KB is generous.
const maxBodyBytes = 64 * 1024

// HttpArena is the Caddy handler module implementing /baseline11.
// It has no configuration — the Caddyfile directive `httparena` takes no
// arguments.
type HttpArena struct{}

// CaddyModule registers the module with Caddy under the id
// `http.handlers.httparena`, which matches the Caddyfile directive name.
func (HttpArena) CaddyModule() caddy.ModuleInfo {
	return caddy.ModuleInfo{
		ID:  "http.handlers.httparena",
		New: func() caddy.Module { return new(HttpArena) },
	}
}

// ServeHTTP implements the /baseline11 contract. GET and POST only; anything
// else gets a 405. Query args are summed as int64, invalid values skipped.
// For POST, the body (capped at maxBodyBytes) is parsed as an integer and
// added. Response is text/plain with the decimal sum and no trailing newline.
func (HttpArena) ServeHTTP(w http.ResponseWriter, r *http.Request, _ caddyhttp.Handler) error {
	if r.Method != http.MethodGet && r.Method != http.MethodPost {
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusMethodNotAllowed)
		_, _ = io.WriteString(w, "Method Not Allowed")
		return nil
	}

	var sum int64
	for _, values := range r.URL.Query() {
		for _, v := range values {
			n, err := strconv.ParseInt(v, 10, 64)
			if err != nil {
				continue
			}
			sum += n
		}
	}

	if r.Method == http.MethodPost && r.Body != nil {
		body, err := io.ReadAll(io.LimitReader(r.Body, maxBodyBytes))
		if err == nil && len(body) > 0 {
			n, err := strconv.ParseInt(string(bytes.TrimSpace(body)), 10, 64)
			if err == nil {
				sum += n
			}
		}
	}

	out := strconv.FormatInt(sum, 10)
	w.Header().Set("Content-Type", "text/plain")
	w.Header().Set("Content-Length", strconv.Itoa(len(out)))
	w.WriteHeader(http.StatusOK)
	if _, err := io.WriteString(w, out); err != nil {
		return fmt.Errorf("httparena: write response: %w", err)
	}
	return nil
}

// parseCaddyfile wires the `httparena` directive into the handler. The
// directive takes no arguments.
func parseCaddyfile(h httpcaddyfile.Helper) (caddyhttp.MiddlewareHandler, error) {
	// Consume the directive token (and reject any args/blocks).
	for h.Next() {
		if h.NextArg() {
			return nil, h.ArgErr()
		}
	}
	return HttpArena{}, nil
}

// UnmarshalCaddyfile satisfies caddyfile.Unmarshaler so the module plays
// nicely with JSON-based configs that reference it by name.
func (HttpArena) UnmarshalCaddyfile(d *caddyfile.Dispenser) error {
	for d.Next() {
		if d.NextArg() {
			return d.ArgErr()
		}
	}
	return nil
}

func init() {
	caddy.RegisterModule(HttpArena{})
	httpcaddyfile.RegisterHandlerDirective("httparena", parseCaddyfile)
}

// Interface guards — compile-time checks that HttpArena satisfies the
// interfaces Caddy expects from a middleware handler module.
var (
	_ caddy.Module                = (*HttpArena)(nil)
	_ caddyhttp.MiddlewareHandler = (*HttpArena)(nil)
	_ caddyfile.Unmarshaler       = (*HttpArena)(nil)
)
