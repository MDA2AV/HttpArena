package main

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"log"
	stdhttp "net/http"
	"os"
	"reflect"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/bytedance/sonic"
	"github.com/bytedance/sonic/encoder"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/klauspost/compress/flate"
	"github.com/klauspost/compress/gzip"
	"github.com/klauspost/compress/zstd"
	fib "github.com/lesismal/fib"
	"github.com/lesismal/fib/grpc"
	fibhttp "github.com/lesismal/fib/http"
	"github.com/lesismal/fib/http3"
	"github.com/lesismal/fib/prefork"
	"github.com/lesismal/fib/taskpool"
	fibtls "github.com/lesismal/fib/tls"
	brrr "github.com/molecule-man/go-brrr"
	"google.golang.org/protobuf/proto"

	pb "httparena/fib-tuned/proto"
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
// through, and the Context the route's parameters. Anything else is answered
// 404, or 405 on a path served for other methods.
//
// The entry's own compression middleware (compress.go), built on fib's
// middleware API, is around the routes whose bodies are JSON: brotli, zstd,
// gzip or deflate, whichever Accept-Encoding prefers, and the body as it is
// when the client asks for none. It sees each response whole, which on HTTP/1
// would keep a file off sendfile, so /static, whose compressed variants are
// already on disk, is left outside it. Its settings are fiber-tuned's,
// compress.LevelBestSpeed on fasthttp: brotli quality 0, gzip and deflate
// level 1 and zstd's fastest level, bodies of 200 bytes or more, and brotli
// first between codings a client weighs the same, so the profile's
// "gzip, br" is answered in brotli.
func newRouter() *fibhttp.Router {
	r := fibhttp.NewRouter()
	r.Get("/baseline11", baseline)
	r.Post("/baseline11", baseline)
	r.Get("/baseline2", baseline)
	r.Get("/pipeline", pipeline)
	r.Post("/echo", echo)
	r.Get("/delay/{ms}", delay)
	r.Get("/static/*", staticFile)
	compressed := r.With(newCompress(CompressConfig{
		MinLength:     defaultMinLength,
		BrotliQuality: brrr.BestSpeed,
		ZstdLevel:     zstd.SpeedFastest,
		GzipLevel:     gzip.BestSpeed,
		DeflateLevel:  flate.BestSpeed,
		Prefer:        defaultPrefer,
	}))
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

func pipeline(c *fibhttp.Context) {
	c.Respond(stdhttp.StatusOK, textPlain, okBody)
}

// a + b from the query, plus the integer in the body on POST. Context.Query
// reads a parameter without building URL.Query's map, and fib reads the body
// whole, Content-Length or chunked, before the handler runs, which
// Context.Body hands over as it is rather than copied out through io.ReadAll.
func baseline(c *fibhttp.Context) {
	sum := queryInt(c.Query("a"), 0) + queryInt(c.Query("b"), 0)
	if c.Request.Method == stdhttp.MethodPost {
		if n, err := strconv.Atoi(strings.TrimSpace(string(c.Body()))); err == nil {
			sum += n
		}
	}
	c.Respond(stdhttp.StatusOK, textPlain, strconv.AppendInt(nil, int64(sum), 10))
}

// The JSON responses are encoded by Context.JSON with sonic, the encoder
// tuned mode names first among what it allows and fiber-tuned uses, which run
// sets as fib's JSONEncoder: json-tls served 1.06M requests a second with it
// against 747k through encoding/json, whose output for these types is the
// same bytes. Its JIT compiles an encoder per type the first time it meets
// one, which run does before load arrives.
func jsonItems(c *fibhttp.Context) {
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

const octetStream = "application/octet-stream"

// echo answers with the request's body. One of up to streamThreshold arrives
// whole before the handler runs, decoded from whichever framing the client
// used: Context.Body is it, and Respond copies it out before it goes back to
// the pool.
//
// A larger one streams, as fit takes an upload it proxies: Context.OnBody
// hands it over as it arrives, on the worker reading the connection, and
// each piece goes straight back out with WriteNoWait, so the body is never
// held whole and no goroutine waits on either side. Once more than the
// response's limit is queued for a client that is behind, the request body
// is held with HoldBody, which stops the connection's reads once
// streamBuffer of it waits, until OnWritable says the client has taken half
// of what was queued. Each such wait is bounded by echoStall: a client that
// stops reading loses its connection, and OnWritable hears of it.
func echo(c *fibhttp.Context) {
	if c.RequestBody() == nil {
		c.Respond(stdhttp.StatusOK, octetStream, c.Body())
		return
	}
	h := c.Header()
	h["Content-Type"] = []string{octetStream}
	if n := c.Request.ContentLength; n >= 0 {
		h["Content-Length"] = []string{strconv.FormatInt(n, 10)}
	}
	// OnBody retains the request until its last call, after which the
	// response is finished, so the handler returns at once.
	c.OnBody(func(data []byte, fin bool, err error) {
		if err != nil || len(data) == 0 {
			return
		}
		above, werr := c.WriteNoWait(data)
		if werr != nil || !above || fin {
			return
		}
		c.HoldBody(true)
		_ = c.SetWriteDeadline(time.Now().Add(echoStall))
		if !c.OnWritable(resumeEcho(c)) {
			// Room already, or nothing more will be written.
			resumeEcho(c)(nil)
		}
	})
}

// echoStall bounds each wait for a client that is behind with its echo.
const echoStall = 10 * time.Second

// resumeEcho lifts the stall deadline and lets the held body go on; after an
// error, so that the request can see its end.
func resumeEcho(c *fibhttp.Context) func(error) {
	return func(error) {
		_ = c.SetWriteDeadline(time.Time{})
		c.HoldBody(false)
	}
}

// delay never waits on fib's worker: the request is retained through
// Context.Async, as fit hands blocking work off its workers, and answered
// from a timer once the delay has passed, so the worker goes straight back
// to the connections that have something to read.
func delay(c *fibhttp.Context) {
	ms, err := strconv.Atoi(c.Param("ms"))
	if err != nil || ms < 0 {
		c.Respond(stdhttp.StatusBadRequest, textPlain, nil)
		return
	}
	body := strconv.AppendInt(nil, int64(ms), 10)
	if ms == 0 {
		c.Respond(stdhttp.StatusOK, textPlain, body)
		return
	}
	time.AfterFunc(time.Duration(ms)*time.Millisecond, c.Async(func() {
		c.Respond(stdhttp.StatusOK, textPlain, body)
	}))
}

// staticFiles serves /static from memory through fib's FileCache, which
// follows the disk: an inotify watch on the directory tells it of a replaced
// file, its compressed twins included, within moments, and it reads the file
// again for the next request, so nothing per request touches the disk. It
// picks the pre-compressed twin on disk off Accept-Encoding, and takes the
// Content-Type from the original's name, or from its bytes where the name
// says none, as ServeContent does. Each prefork child has its own.
var staticFiles *fibhttp.FileCache

func staticFile(c *fibhttp.Context) {
	if staticFiles == nil {
		c.Respond(stdhttp.StatusNotFound, textPlain, nil)
		return
	}
	staticFiles.ServeFile(c, c.Param("*"))
}

// itemsResponse is /async-db's body.
type itemsResponse struct {
	Items []DatasetItem `json:"items"`
	Count int           `json:"count"`
}

var pgPool *pgxpool.Pool

// dbTasks runs /async-db's queries off fib's workers: a pool of as many
// workers as the database pool has connections, so that a query never waits
// on a goroutine of its own for a connection, and the requests past them
// wait in its queue rather than each on a goroutine.
var dbTasks *taskpool.TaskPool

// dbQueue is how many queries may wait for a worker; past it a query runs on
// a goroutine of its own rather than holding a fib worker up.
const dbQueue = 16 << 10

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
	// Opened whole at startup, as fiber-tuned's is, rather than lazily, so
	// that the first requests of a run do not each pay for a connect and a
	// Postgres handshake.
	cfg.MinConns = cfg.MaxConns
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		return
	}
	pgPool = pool
	dbTasks = taskpool.New("async-db", int(cfg.MaxConns), dbQueue)
}

// The query blocks, so the request is retained through Context.Async and
// the query handed to dbTasks, as fit hands blocking work to a pool of its
// own, leaving fib's worker free for other connections. It runs under the
// request's Context, which is cancelled once the client has gone, so an
// abandoned query gives its connection back.
func asyncDB(c *fibhttp.Context) {
	if pgPool == nil {
		c.Respond(stdhttp.StatusOK, appJSON, []byte(emptyItems))
		return
	}
	minPrice := queryInt(c.Query("min"), 10)
	maxPrice := queryInt(c.Query("max"), 50)
	limit := clamp(queryInt(c.Query("limit"), 50), 1, 50)
	run := c.Async(func() {
		items, err := queryItems(c.Context(),
			"SELECT "+itemColumns+" FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
			minPrice, maxPrice, limit)
		if err != nil {
			c.Respond(stdhttp.StatusInternalServerError, textPlain, nil)
			return
		}
		if err := c.JSON(stdhttp.StatusOK, itemsResponse{items, len(items)}); err != nil {
			c.Respond(stdhttp.StatusInternalServerError, textPlain, nil)
		}
	})
	if !dbTasks.TryGo(run) {
		go run()
	}
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

// streamThreshold is the body size past which a request body streams to its
// handler rather than being read whole first, and streamBuffer how much of a
// streamed HTTP/1 body waits unread before the connection stops reading the
// client: fit's figures, one 64 KiB read each, rather than fib's 256 KiB
// buffer, so that a large body waits in the client's TCP rather than in the
// server's memory.
const (
	streamThreshold = 64 << 10
	streamBuffer    = 64 << 10
)

// httpConfig is fib's default HTTP config with request bodies past
// streamThreshold streamed to their handlers, as fit configures its
// listeners, and a streamed body bounded as one read whole is. h1Only serves
// HTTP/1.1 alone. gRPC calls stream past the threshold too, which fib's grpc
// package reads as they arrive; they are not streamed from their headers, as
// fit's proxy does for clients that wait on a reply mid-call, since
// BenchmarkService's calls are unary.
func httpConfig(h1Only bool) fibhttp.Config {
	c := fibhttp.DefaultConfig()
	c.DisableHTTP2 = h1Only
	c.StreamRequestBody = true
	c.StreamRequestBodyThreshold = streamThreshold
	c.StreamRequestBodyBuffer = streamBuffer
	c.MaxStreamedBodyBytes = c.MaxBodyBytes
	return c
}

// http3Config is httpConfig for HTTP/3.
func http3Config(tlsConfig *tls.Config) http3.Config {
	c := http3.DefaultConfig()
	c.TLSConfig = tlsConfig
	c.StreamRequestBody = true
	c.StreamRequestBodyThreshold = streamThreshold
	c.MaxStreamedBodyBytes = c.MaxBodyBytes
	return c
}

// run binds the entry's listeners and serves until ctx is done. It runs in
// each of the processes main starts through fib's prefork, so the dataset,
// the database pool and the engine are each child's own.
//
// Every listener is a fib.Binding of one engine, which serves each with the
// binding's own handler on a single event loop, task pool and buffer pool.
func run(ctx context.Context) error {
	if fc, err := fibhttp.NewFileCache(fibhttp.FileCacheConfig{Root: "/data/static", Precompressed: true}); err == nil {
		staticFiles = fc
	}
	fibhttp.JSONEncoder = func(dst []byte, v any) ([]byte, error) {
		err := encoder.EncodeInto(&dst, v, 0)
		return dst, err
	}
	for _, t := range []reflect.Type{reflect.TypeOf(ProcessResponse{}), reflect.TypeOf(itemsResponse{})} {
		if err := sonic.Pretouch(t); err != nil {
			log.Printf("sonic pretouch %s: %v", t, err)
		}
	}
	loadDataset()
	loadPgPool()

	handler := newRouter()

	// Plaintext: HTTP/1.1 on 8080 and HTTP/2 with prior knowledge on 8082.
	// fib's HTTP handler tells the two apart by the connection preface, so one
	// binding listens on both ports.
	plain := fibhttp.NewHandlerWithConfig(httpConfig(false), handler)
	bindings := []fib.Binding{{Addrs: []string{":8080", ":8082"}, Handler: plain}}

	// The HTTP/1.1-only listeners over TLS offer http/1.1 alone through ALPN.
	h1Handler := fibhttp.NewHandlerWithConfig(httpConfig(true), handler)

	if tlsConfig := loadTLS(); tlsConfig != nil {
		// 8081: HTTP/1.1 over TLS (json-tls, static-tls, 8gbit).
		h1TLS := tlsConfig.Clone()
		h1TLS.NextProtos = []string{"http/1.1"}
		bindings = append(bindings,
			fib.Binding{Addr: ":8081", Handler: fibtls.NewServer(h1TLS, h1Handler)},
			// 8443/tcp: HTTP/2 through ALPN, HTTP/1.1 for clients that do not
			// choose it.
			fib.Binding{Addr: ":8443", Handler: fibtls.NewServer(fibhttp.ConfigureTLS(tlsConfig), fibhttp.NewHandlerWithConfig(httpConfig(false), handler))},
			// 8443/udp: HTTP/3 over fib's own QUIC.
			fib.Binding{Network: "udp", Addr: ":8443", Handler: http3.NewHandlerWithConfig(http3Config(tlsConfig), handler)},
		)
	}

	// 9000: the opt-in TLS hardening section, HTTP/1.1 over TLS with its own
	// certificate directory, which the harness replaces underneath the running
	// server. The certificate is picked per handshake, so a renewed pair is
	// served without a restart.
	if certs := newCertReloader("/certs-tls/server.crt", "/certs-tls/server.key"); certs != nil {
		hardened := &tls.Config{GetCertificate: certs.GetCertificate, NextProtos: []string{"http/1.1"}}
		bindings = append(bindings, fib.Binding{Addr: ":9000", Handler: fibtls.NewServer(hardened, h1Handler)})
	}

	engine, err := fib.New(fib.DefaultConfig(), bindings...)
	if err != nil {
		log.Fatalf("fib: listen: %v", err)
	}
	go func() {
		<-ctx.Done()
		engine.Stop()
	}()
	// Run returns nil once Stop has been called, and an error only when the
	// event loop itself failed.
	return engine.Run()
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
