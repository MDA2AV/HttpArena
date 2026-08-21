// The /json/{count}?m={multiplier} contract, as a second Caddy handler module.
//
// The dataset is read once at provision time; the response is built and
// serialized per request from those values. Nothing is cached between
// requests: the multiplier varies per request template, so a response keyed
// on the path alone would return wrong totals — and caching is what this
// profile exists to rule out.
package httparena

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strconv"
	"strings"

	"github.com/caddyserver/caddy/v2"
	"github.com/caddyserver/caddy/v2/caddyconfig/caddyfile"
	"github.com/caddyserver/caddy/v2/caddyconfig/httpcaddyfile"
	"github.com/caddyserver/caddy/v2/modules/caddyhttp"
)

// datasetPath is where the harness mounts the 50-item dataset.
const datasetPath = "/data/dataset.json"

type rating struct {
	Score int64 `json:"score"`
	Count int64 `json:"count"`
}

// item is one dataset entry. Total is derived per request (price × quantity ×
// m), so it is absent from the file and always written by the handler.
type item struct {
	ID       int64    `json:"id"`
	Name     string   `json:"name"`
	Category string   `json:"category"`
	Price    int64    `json:"price"`
	Quantity int64    `json:"quantity"`
	Active   bool     `json:"active"`
	Tags     []string `json:"tags"`
	Rating   rating   `json:"rating"`
	Total    int64    `json:"total"`
}

type jsonResponse struct {
	Items []item `json:"items"`
	Count int    `json:"count"`
}

// HttpArenaJSON is the Caddy handler module implementing /json/{count}.
// The Caddyfile directive `httparena_json` takes no arguments.
type HttpArenaJSON struct {
	dataset []item
}

// CaddyModule registers the module under `http.handlers.httparena_json`.
func (HttpArenaJSON) CaddyModule() caddy.ModuleInfo {
	return caddy.ModuleInfo{
		ID:  "http.handlers.httparena_json",
		New: func() caddy.Module { return new(HttpArenaJSON) },
	}
}

// Provision loads the dataset. A missing or malformed file is a startup
// error rather than a per-request 500 — the entry should fail validation
// loudly instead of serving wrong data quickly.
func (h *HttpArenaJSON) Provision(caddy.Context) error {
	raw, err := os.ReadFile(datasetPath)
	if err != nil {
		return fmt.Errorf("httparena_json: read %s: %w", datasetPath, err)
	}
	if err := json.Unmarshal(raw, &h.dataset); err != nil {
		return fmt.Errorf("httparena_json: parse %s: %w", datasetPath, err)
	}
	if len(h.dataset) == 0 {
		return fmt.Errorf("httparena_json: %s is empty", datasetPath)
	}
	return nil
}

// ServeHTTP implements GET /json/{count}?m={multiplier}. count is clamped to
// the dataset; m defaults to 1 when absent or unparseable.
func (h *HttpArenaJSON) ServeHTTP(w http.ResponseWriter, r *http.Request, _ caddyhttp.Handler) error {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusMethodNotAllowed)
		_, _ = w.Write([]byte("Method Not Allowed"))
		return nil
	}

	rest := strings.TrimPrefix(r.URL.Path, "/json/")
	count, err := strconv.Atoi(rest)
	if err != nil || count < 1 || count > len(h.dataset) {
		w.Header().Set("Content-Type", "text/plain")
		w.WriteHeader(http.StatusBadRequest)
		_, _ = w.Write([]byte("Bad Request"))
		return nil
	}

	m := int64(1)
	if v := r.URL.Query().Get("m"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			m = n
		}
	}

	items := make([]item, count)
	for i := 0; i < count; i++ {
		it := h.dataset[i]
		it.Total = it.Price * it.Quantity * m
		items[i] = it
	}

	body, err := json.Marshal(jsonResponse{Items: items, Count: count})
	if err != nil {
		return fmt.Errorf("httparena_json: marshal: %w", err)
	}

	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(http.StatusOK)
	if r.Method == http.MethodHead {
		return nil
	}
	if _, err := w.Write(body); err != nil {
		return fmt.Errorf("httparena_json: write response: %w", err)
	}
	return nil
}

// parseCaddyfileJSON wires the `httparena_json` directive, which takes no
// arguments.
func parseCaddyfileJSON(h httpcaddyfile.Helper) (caddyhttp.MiddlewareHandler, error) {
	for h.Next() {
		if h.NextArg() {
			return nil, h.ArgErr()
		}
	}
	return new(HttpArenaJSON), nil
}

// UnmarshalCaddyfile satisfies caddyfile.Unmarshaler for JSON-based configs.
func (*HttpArenaJSON) UnmarshalCaddyfile(d *caddyfile.Dispenser) error {
	for d.Next() {
		if d.NextArg() {
			return d.ArgErr()
		}
	}
	return nil
}

func init() {
	caddy.RegisterModule(new(HttpArenaJSON))
	httpcaddyfile.RegisterHandlerDirective("httparena_json", parseCaddyfileJSON)
}

// Interface guards.
var (
	_ caddy.Module                = (*HttpArenaJSON)(nil)
	_ caddy.Provisioner           = (*HttpArenaJSON)(nil)
	_ caddyhttp.MiddlewareHandler = (*HttpArenaJSON)(nil)
	_ caddyfile.Unmarshaler       = (*HttpArenaJSON)(nil)
)
