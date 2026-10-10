package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"log"
	stdhttp "net/http"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	fib "github.com/lesismal/fib"
	"github.com/lesismal/fib/grpc"
	fibhttp "github.com/lesismal/fib/http"
	"github.com/lesismal/fib/http3"
	"github.com/lesismal/fib/middleware/compress"
	"github.com/lesismal/fib/prefork"
	fibtls "github.com/lesismal/fib/tls"
	"google.golang.org/protobuf/proto"

	pb "httparena/fib/proto"
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

// okBody is /pipeline's answer, made once: Respond copies it, so one slice
// serves every response.
var okBody = []byte("ok")

// newRouter routes the entry's requests through fib's Router, whose API is
// chi's with fib's handlers. The same router answers HTTP/1.1, HTTP/2 and
// HTTP/3: fib hands each of them a *http.Request and a Context to respond
// through, and the Context the route's parameters. Anything else is
// answered 404, or 405 on a path served for other methods.
//
// fib's compression middleware, with its defaults, is around the routes
// whose bodies are JSON: it gzips a body of a kilobyte or more when
// Accept-Encoding takes it, and leaves it alone otherwise. It sees each
// response whole, which on HTTP/1 would keep a file off sendfile, so
// /static, whose compressed variants are already on disk, is left outside it.
func newRouter() *fibhttp.Router {
	r := fibhttp.NewRouter()
	r.Get("/baseline11", baseline)
	r.Post("/baseline11", baseline)
	r.Get("/baseline2", baseline)
	r.Get("/pipeline", pipeline)
	r.Post("/echo", echo)
	r.Get("/delay/{ms}", delay)
	r.Get("/static/*", staticFile)
	compressed := r.With(compress.New())
	compressed.Get("/json/{count}", jsonItems)
	compressed.Get("/async-db", asyncDB)
	r.Handle("/benchmark.BenchmarkService/*", newGRPCServer())
	return r
}

// newGRPCServer serves BenchmarkService through fib's grpc package, whose
// Server answers the calls its routes hand it from fib's HTTP/2, so gRPC
// shares 8080 (h2c with prior knowledge) and 8443 (h2 over TLS) with the
// HTTP the other profiles send there. The service's code is what protoc
// generates, its messages google.golang.org/protobuf's.
func newGRPCServer() *grpc.Server {
	server := grpc.NewServer()
	pb.RegisterBenchmarkServiceServer(server, benchmarkService{})
	return server
}

type benchmarkService struct {
	pb.UnimplementedBenchmarkServiceServer
}

func (benchmarkService) GetSum(_ context.Context, req *pb.SumRequest) (*pb.SumReply, error) {
	return &pb.SumReply{Result: req.A + req.B}, nil
}

// protoCodec encodes the messages with google.golang.org/protobuf, which fib's
// grpc package, depending on nothing outside the standard library, leaves to
// the program.
type protoCodec struct{}

func (protoCodec) Name() string                    { return "proto" }
func (protoCodec) Marshal(v any) ([]byte, error)   { return proto.Marshal(v.(proto.Message)) }
func (protoCodec) Unmarshal(b []byte, v any) error { return proto.Unmarshal(b, v.(proto.Message)) }

func init() { grpc.RegisterCodec(protoCodec{}) }

func pipeline(c *fibhttp.Context, r *stdhttp.Request) {
	c.Respond(stdhttp.StatusOK, textPlain, okBody)
}

// a + b from the query, plus the integer in the body on POST. Context.Query
// reads a parameter without building URL.Query's map, and fib reads the body
// whole, Content-Length or chunked, before the handler runs, which
// Context.Body hands over as it is rather than copied out through io.ReadAll.
func baseline(c *fibhttp.Context, r *stdhttp.Request) {
	sum := queryInt(c.Query("a"), 0) + queryInt(c.Query("b"), 0)
	if r.Method == stdhttp.MethodPost {
		if n, err := strconv.Atoi(strings.TrimSpace(string(c.Body()))); err == nil {
			sum += n
		}
	}
	c.Respond(stdhttp.StatusOK, textPlain, strconv.AppendInt(nil, int64(sum), 10))
}

func jsonItems(c *fibhttp.Context, r *stdhttp.Request) {
	count, err := strconv.Atoi(c.Param("count"))
	if err != nil {
		c.Respond(stdhttp.StatusBadRequest, textPlain, nil)
		return
	}
	count = clamp(count, 0, len(dataset))
	m := queryInt(c.Query("m"), 1)
	items := make([]ProcessedItem, count)
	for i := range items {
		d := dataset[i]
		items[i] = ProcessedItem{DatasetItem: d, Total: d.Price * d.Quantity * m}
	}
	if err := c.JSON(stdhttp.StatusOK, ProcessResponse{Items: items, Count: count}); err != nil {
		c.Respond(stdhttp.StatusInternalServerError, textPlain, nil)
	}
}

// The body arrives already read off the connection, decoded from whichever
// framing the client used, so the echo is the bytes that came in: Context.Body
// is them, and Respond copies them out before they go back to the pool.
func echo(c *fibhttp.Context, r *stdhttp.Request) {
	c.Respond(stdhttp.StatusOK, "application/octet-stream", c.Body())
}

// The handler waits out the delay itself, as fiber's does in its connection's
// goroutine: fib's worker pool grows for handlers that block, so a waiting
// request holds a worker the way it holds a goroutine there. Retaining the
// request and answering it from time.AfterFunc instead started a goroutine
// per request for the timer's callback, and on 64 CPUs served 1.40M requests
// a second against 1.63M waiting in the handler.
func delay(c *fibhttp.Context, r *stdhttp.Request) {
	ms, err := strconv.Atoi(c.Param("ms"))
	if err != nil || ms < 0 {
		c.Respond(stdhttp.StatusBadRequest, textPlain, nil)
		return
	}
	if ms > 0 {
		time.Sleep(time.Duration(ms) * time.Millisecond)
	}
	c.Respond(stdhttp.StatusOK, textPlain, strconv.AppendInt(nil, int64(ms), 10))
}

// staticFiles serves /static from memory through fib's FileCache, which
// follows the disk: an inotify watch on the directory tells it of a replaced
// file, its compressed twins included, within moments, and it reads the file
// again for the next request, so nothing per request touches the disk. It
// picks the pre-compressed twin on disk off Accept-Encoding, and takes the
// Content-Type from the original's name, or from its bytes where the name
// says none, as ServeContent does. Each prefork child has its own.
var staticFiles *fibhttp.FileCache

func staticFile(c *fibhttp.Context, r *stdhttp.Request) {
	if staticFiles == nil {
		c.Respond(stdhttp.StatusNotFound, textPlain, nil)
		return
	}
	staticFiles.ServeFile(c, r, c.Param("*"))
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
	budget := 256
	if v := os.Getenv("DATABASE_MAX_CONN"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			budget = n
		}
	}
	// The budget is the container's: every prefork child opens a pool of
	// its own against the same server, so each takes its share.
	cfg.MaxConns = int32(max(1, budget/prefork.Children()))
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
	minPrice := queryInt(c.Query("min"), 10)
	maxPrice := queryInt(c.Query("max"), 50)
	limit := clamp(queryInt(c.Query("limit"), 50), 1, 50)
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
		if err := c.JSON(stdhttp.StatusOK, struct {
			Items []DatasetItem `json:"items"`
			Count int           `json:"count"`
		}{items, len(items)}); err != nil {
			c.Respond(stdhttp.StatusInternalServerError, textPlain, nil)
		}
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

// run binds the entry's engines and serves until ctx is done. It runs in
// each of the processes main starts through fib's prefork, so the dataset,
// the database pool and the engines are each child's own.
func run(ctx context.Context) error {
	if fc, err := fibhttp.NewFileCache(fibhttp.FileCacheConfig{Root: "/data/static", Precompressed: true}); err == nil {
		staticFiles = fc
	}
	loadDataset()
	loadPgPool()

	handler := newRouter()

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

	go func() {
		<-ctx.Done()
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
			return err
		}
	}
	return nil
}

// fib's prefork serves the entry from a process for every two CPUs, each
// with two Ps and a heap and collector of its own, all listening on the same
// ports through SO_REUSEPORT, as fiber's EnablePrefork does with one P each.
// In one process the collector's mark phase shares its work buffers, and the
// heap its lock, between 64 Ps: json-tls served 0.56M requests a second that
// way and 0.87M from 32 children, and latency-1m's 99th percentile fell from
// 1.6ms to 124us. A second P per child keeps it serving while its event loop
// or a handler waits in a system call, which a child of one P cannot.
func main() {
	if err := prefork.Run(prefork.Config{}, run); err != nil {
		log.Fatalf("fib: %v", err)
	}
}
