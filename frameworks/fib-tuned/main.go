package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"io"
	"log"
	stdhttp "net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	fib "github.com/lesismal/fib"
	fibhttp "github.com/lesismal/fib/http"
	"github.com/lesismal/fib/http3"
	"github.com/lesismal/fib/middleware"
	fibtls "github.com/lesismal/fib/tls"
)

type Rating struct {
	Score int `json:"score"`
	Count int `json:"count"`
}

type DatasetItem struct {
	ID       int      `json:"id"`
	Name     string   `json:"name"`
	Category string   `json:"category"`
	Price    int      `json:"price"`
	Quantity int      `json:"quantity"`
	Active   bool     `json:"active"`
	Tags     []string `json:"tags"`
	Rating   Rating   `json:"rating"`
}

type ProcessedItem struct {
	DatasetItem
	Total int `json:"total"`
}

type ProcessResponse struct {
	Items []ProcessedItem `json:"items"`
	Count int             `json:"count"`
}

var dataset []DatasetItem

// A missing or unreadable dataset leaves the list empty, the server still starts.
func loadDataset() {
	path := os.Getenv("DATASET_PATH")
	if path == "" {
		path = "/data/dataset.json"
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	json.Unmarshal(data, &dataset)
}

const (
	textPlain = "text/plain"
	appJSON   = "application/json"
)

// The entry's own compression middleware (compress.go), built on fib's
// middleware API, around the routes whose bodies are JSON: brotli, zstd, gzip
// or deflate, whichever Accept-Encoding prefers, and the body as it is when the
// client asks for none. It sees each response whole, which on HTTP/1 would
// keep a file off sendfile, so /static, whose compressed variants are already
// on disk, is left outside it.
var (
	compressJSON   = newCompress(CompressConfig{})
	jsonHandler    = middleware.Chain(fibhttp.HandlerFunc(jsonItems), compressJSON)
	asyncDBHandler = middleware.Chain(fibhttp.HandlerFunc(asyncDB), compressJSON)
)

// fib has no router, so the handler every protocol shares dispatches on the
// path itself. The same function answers HTTP/1.1, HTTP/2 and HTTP/3: fib
// hands each of them a *http.Request and a Context to respond through.
func serve(c *fibhttp.Context, r *stdhttp.Request) {
	path := r.URL.Path
	switch {
	case path == "/baseline11" || path == "/baseline2":
		baseline(c, r)
	case path == "/pipeline":
		c.Respond(stdhttp.StatusOK, textPlain, []byte("ok"))
	case strings.HasPrefix(path, "/json/"):
		jsonHandler.ServeHTTP(c, r)
	case path == "/echo":
		echo(c, r)
	case strings.HasPrefix(path, "/delay/"):
		delay(c, path[len("/delay/"):])
	case strings.HasPrefix(path, "/static/"):
		staticFile(c, r, path[len("/static/"):])
	case path == "/async-db":
		asyncDBHandler.ServeHTTP(c, r)
	default:
		c.Respond(stdhttp.StatusNotFound, textPlain, nil)
	}
}

// Sum of every integer query parameter, plus the integer in the body on POST.
// fib reads the body whole, Content-Length or chunked, before the handler runs.
func baseline(c *fibhttp.Context, r *stdhttp.Request) {
	sum := 0
	for _, values := range r.URL.Query() {
		for _, v := range values {
			if n, err := strconv.Atoi(v); err == nil {
				sum += n
			}
		}
	}
	if r.Method == stdhttp.MethodPost {
		if body, err := io.ReadAll(r.Body); err == nil {
			if n, err := strconv.Atoi(strings.TrimSpace(string(body))); err == nil {
				sum += n
			}
		}
	}
	c.Respond(stdhttp.StatusOK, textPlain, strconv.AppendInt(nil, int64(sum), 10))
}

func jsonItems(c *fibhttp.Context, r *stdhttp.Request) {
	count, err := strconv.Atoi(strings.TrimPrefix(r.URL.Path, "/json/"))
	if err != nil {
		c.Respond(stdhttp.StatusBadRequest, textPlain, nil)
		return
	}
	count = clamp(count, 0, len(dataset))
	m := 1
	if v := r.URL.Query().Get("m"); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			m = n
		}
	}
	items := make([]ProcessedItem, count)
	for i := range items {
		d := dataset[i]
		items[i] = ProcessedItem{DatasetItem: d, Total: d.Price * d.Quantity * m}
	}
	body, err := json.Marshal(ProcessResponse{Items: items, Count: count})
	if err != nil {
		c.Respond(stdhttp.StatusInternalServerError, textPlain, nil)
		return
	}
	c.Respond(stdhttp.StatusOK, appJSON, body)
}

// The body arrives already read off the connection, decoded from whichever
// framing the client used, so the echo is the bytes that came in.
func echo(c *fibhttp.Context, r *stdhttp.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		c.Respond(stdhttp.StatusBadRequest, textPlain, nil)
		return
	}
	c.Respond(stdhttp.StatusOK, "application/octet-stream", body)
}

// A waiting request must not hold the worker that runs it: Retain keeps the
// response open past the handler's return, and the timer answers it later.
func delay(c *fibhttp.Context, arg string) {
	ms, err := strconv.Atoi(arg)
	if err != nil || ms < 0 {
		c.Respond(stdhttp.StatusBadRequest, textPlain, nil)
		return
	}
	body := strconv.AppendInt(nil, int64(ms), 10)
	if ms == 0 {
		c.Respond(stdhttp.StatusOK, textPlain, body)
		return
	}
	c.Retain()
	time.AfterFunc(time.Duration(ms)*time.Millisecond, func() {
		c.Respond(stdhttp.StatusOK, textPlain, body)
		c.Release()
	})
}

const staticDir = "/data/static/"

// Static files go through net/http's ServeContent, which fib documents for
// its Context: it answers through the Context as a ResponseWriter, and on a
// plaintext HTTP/1 connection the file goes to the socket by sendfile. Every
// request opens the file, so a replaced file is served as it is on disk. The
// pre-compressed twin on disk is chosen off Accept-Encoding; ServeContent
// takes the Content-Type from the original name, or sniffs it from the bytes
// for a type the extension does not say, which only the fonts need and which
// have no compressed twin.
func staticFile(c *fibhttp.Context, r *stdhttp.Request, name string) {
	if name == "" || strings.ContainsAny(name, "/\\") || strings.Contains(name, "..") {
		c.Respond(stdhttp.StatusNotFound, textPlain, nil)
		return
	}
	base := staticDir + name
	f, encoding := openVariant(base, r.Header.Get("Accept-Encoding"))
	if f == nil {
		c.Respond(stdhttp.StatusNotFound, textPlain, nil)
		return
	}
	defer f.Close()
	info, err := f.Stat()
	if err != nil || info.IsDir() {
		c.Respond(stdhttp.StatusNotFound, textPlain, nil)
		return
	}
	if encoding != "" {
		h := c.Header()
		h.Set("Content-Encoding", encoding)
		h.Set("Vary", "Accept-Encoding")
		// ServeContent leaves Content-Length out once Content-Encoding is set,
		// which would send the twin chunked over HTTP/1.1. A whole-file answer
		// knows its length; a range request is left for ServeContent to size.
		if r.Header.Get("Range") == "" {
			h.Set("Content-Length", strconv.FormatInt(info.Size(), 10))
		}
	}
	stdhttp.ServeContent(c, r, name, info.ModTime(), f)
}

// openVariant opens the brotli or gzip twin of base when the client takes that
// coding and the twin exists, and base itself otherwise.
func openVariant(base, acceptEncoding string) (*os.File, string) {
	for _, coding := range [...]struct{ name, suffix string }{{"br", ".br"}, {"gzip", ".gz"}} {
		if acceptsCoding(acceptEncoding, coding.name) {
			if f, err := os.Open(base + coding.suffix); err == nil {
				return f, coding.name
			}
		}
	}
	f, err := os.Open(base)
	if err != nil {
		return nil, ""
	}
	return f, ""
}

// acceptsCoding reports whether an Accept-Encoding value lists coding with a
// q value above zero.
func acceptsCoding(header, coding string) bool {
	for header != "" {
		var part string
		part, header, _ = strings.Cut(header, ",")
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
				return err != nil || q > 0
			}
		}
		return true
	}
	return false
}

var pgPool *pgxpool.Pool

const itemColumns = "id, name, category, price, quantity, active, tags, rating_score, rating_count"

const emptyItems = `{"items":[],"count":0}`

// The pool is sized from DATABASE_MAX_CONN, as the async-db profile asks,
// rather than from pgxpool's CPU-count default. One process here, so the
// whole budget is ours.
func loadPgPool() {
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		return
	}
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		return
	}
	cfg.MaxConns = 256
	if v := os.Getenv("DATABASE_MAX_CONN"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			cfg.MaxConns = int32(n)
		}
	}
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		return
	}
	pgPool = pool
}

// The query blocks, so it runs on a goroutine of its own and answers the
// retained request from there, leaving fib's worker free for other connections.
func asyncDB(c *fibhttp.Context, r *stdhttp.Request) {
	if pgPool == nil {
		c.Respond(stdhttp.StatusOK, appJSON, []byte(emptyItems))
		return
	}
	q := r.URL.Query()
	minPrice := queryInt(q.Get("min"), 10)
	maxPrice := queryInt(q.Get("max"), 50)
	limit := clamp(queryInt(q.Get("limit"), 50), 1, 50)
	c.Retain()
	go func() {
		defer c.Release()
		items, err := queryItems(context.Background(),
			"SELECT "+itemColumns+" FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
			minPrice, maxPrice, limit)
		if err != nil {
			c.Respond(stdhttp.StatusInternalServerError, textPlain, nil)
			return
		}
		body, err := json.Marshal(struct {
			Items []DatasetItem `json:"items"`
			Count int           `json:"count"`
		}{items, len(items)})
		if err != nil {
			c.Respond(stdhttp.StatusInternalServerError, textPlain, nil)
			return
		}
		c.Respond(stdhttp.StatusOK, appJSON, body)
	}()
}

// tags is a JSONB column, so it comes back as bytes rather than a Go slice.
func queryItems(ctx context.Context, sql string, args ...any) ([]DatasetItem, error) {
	rows, err := pgPool.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []DatasetItem{}
	for rows.Next() {
		var it DatasetItem
		var tags []byte
		if err := rows.Scan(&it.ID, &it.Name, &it.Category, &it.Price, &it.Quantity,
			&it.Active, &tags, &it.Rating.Score, &it.Rating.Count); err != nil {
			continue
		}
		json.Unmarshal(tags, &it.Tags)
		if it.Tags == nil {
			it.Tags = []string{}
		}
		items = append(items, it)
	}
	return items, rows.Err()
}

func queryInt(v string, fallback int) int {
	if n, err := strconv.Atoi(v); err == nil {
		return n
	}
	return fallback
}

func clamp(v, lo, hi int) int {
	return min(max(v, lo), hi)
}

// The harness only mounts /certs for the TLS profiles, so without them the TLS
// listeners are not opened.
func loadTLS() *tls.Config {
	const certFile, keyFile = "/certs/server.crt", "/certs/server.key"
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return nil
	}
	return &tls.Config{Certificates: []tls.Certificate{cert}}
}

// certReloader serves the pair at certFile and keyFile, and loads it again on
// the first handshake after either file has changed.
type certReloader struct {
	certFile, keyFile string

	mu    sync.Mutex
	stamp [2]fileStamp
	cert  *tls.Certificate
}

type fileStamp struct {
	modTime time.Time
	size    int64
}

func newCertReloader(certFile, keyFile string) *certReloader {
	r := &certReloader{certFile: certFile, keyFile: keyFile}
	if _, err := r.GetCertificate(nil); err != nil {
		return nil
	}
	return r
}

func (r *certReloader) GetCertificate(*tls.ClientHelloInfo) (*tls.Certificate, error) {
	stamp := [2]fileStamp{statFile(r.certFile), statFile(r.keyFile)}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.cert != nil && stamp == r.stamp {
		return r.cert, nil
	}
	cert, err := tls.LoadX509KeyPair(r.certFile, r.keyFile)
	if err != nil {
		// A pair caught halfway through being replaced does not load, since
		// the key no longer matches the certificate: keep serving the last
		// good one and try again on the next handshake.
		if r.cert != nil {
			return r.cert, nil
		}
		return nil, err
	}
	r.cert, r.stamp = &cert, stamp
	return r.cert, nil
}

func statFile(name string) fileStamp {
	info, err := os.Stat(name)
	if err != nil {
		return fileStamp{}
	}
	return fileStamp{info.ModTime(), info.Size()}
}

func bind(network string, addrs []string, handler fib.Handler) *fib.Engine {
	config := fib.DefaultConfig()
	config.Network = network
	config.Addrs = addrs
	engine, err := fib.Bind(config, handler)
	if err != nil {
		log.Fatalf("fib: bind %s %v: %v", network, addrs, err)
	}
	return engine
}

func main() {
	loadDataset()
	loadPgPool()

	handler := fibhttp.HandlerFunc(serve)

	// Plaintext: HTTP/1.1 on 8080 and HTTP/2 with prior knowledge on 8082.
	// fib's HTTP handler tells the two apart by the connection preface, so one
	// engine listens on both ports.
	engines := []*fib.Engine{bind("tcp", []string{":8080", ":8082"}, fibhttp.NewHandler(handler))}

	// The HTTP/1.1-only listeners over TLS offer http/1.1 alone through ALPN.
	h1Config := fibhttp.DefaultConfig()
	h1Config.DisableHTTP2 = true
	h1Handler := fibhttp.NewHandlerWithConfig(h1Config, handler)

	if tlsConfig := loadTLS(); tlsConfig != nil {
		// 8081: HTTP/1.1 over TLS (json-tls, static-tls, 8gbit).
		h1TLS := tlsConfig.Clone()
		h1TLS.NextProtos = []string{"http/1.1"}
		engines = append(engines, bind("tcp", []string{":8081"}, fibtls.NewServer(h1TLS, h1Handler)))

		// 8443/tcp: HTTP/2 through ALPN, HTTP/1.1 for clients that do not
		// choose it.
		engines = append(engines, bind("tcp", []string{":8443"},
			fibtls.NewServer(fibhttp.ConfigureTLS(tlsConfig), fibhttp.NewHandler(handler))))

		// 8443/udp: HTTP/3 over fib's own QUIC.
		engines = append(engines, bind("udp", []string{":8443"}, http3.NewHandler(tlsConfig, handler)))
	}

	// 9000: the opt-in TLS hardening section, HTTP/1.1 over TLS with its own
	// certificate directory, which the harness replaces underneath the running
	// server. The certificate is picked per handshake, so a renewed pair is
	// served without a restart.
	if certs := newCertReloader("/certs-tls/server.crt", "/certs-tls/server.key"); certs != nil {
		hardened := &tls.Config{GetCertificate: certs.GetCertificate, NextProtos: []string{"http/1.1"}}
		engines = append(engines, bind("tcp", []string{":9000"}, fibtls.NewServer(hardened, h1Handler)))
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-stop
		for _, e := range engines {
			e.Stop()
		}
	}()

	errs := make(chan error, len(engines))
	for _, e := range engines {
		go func() { errs <- e.Run() }()
	}
	// Run returns nil once Stop has been called, and an error only when the
	// event loop itself failed.
	for range engines {
		if err := <-errs; err != nil {
			log.Fatalf("fib: %v", err)
		}
	}
}
