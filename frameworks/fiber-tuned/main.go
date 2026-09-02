// fiber-tuned is the fiber entry with what the standard entry leaves at the
// framework's defaults: sonic in place of encoding/json, the compress
// middleware at its best-speed level, the Postgres pool opened to its full
// size at startup rather than lazily, and - in go.mod, not here - fasthttp at
// master instead of the v1.73.0 Fiber 3.5.0 pins, for the go-brrr brotli that
// valyala/fasthttp#2366 swapped in. Everything else - the routes, prefork, the
// static and TLS paths, the shutdown - is the standard entry's, unchanged, and
// its README explains those.
package main

import (
	"context"
	"crypto/tls"
	"log"
	"os"
	"os/signal"
	"path/filepath"
	"reflect"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/bytedance/sonic"
	"github.com/gofiber/fiber/v3"
	"github.com/gofiber/fiber/v3/middleware/compress"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

// How long a worker keeps serving after it is signalled, before it stops
// waiting for the requests still in flight.
const shutdownGrace = 3 * time.Second

// Closed once the shutdown started by a signal has finished, so main can wait
// for it. Nil when this process is not serving.
var drained chan struct{}

// workerProcesses is how many processes end up sharing anything the container
// holds once - the connection budget below, most of all.
//
// Prefork forks GOMAXPROCS children, the value read in the master before it
// spawns anything. A child re-runs main() from the top and reads the same
// number here, because the GOMAXPROCS(1) that prefork applies to a child
// happens later, when it takes its listener.
func workerProcesses() int {
	return runtime.GOMAXPROCS(0)
}

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

func loadDataset() {
	path := os.Getenv("DATASET_PATH")
	if path == "" {
		path = "/data/dataset.json"
	}
	// Logged rather than swallowed: with no dataset every /json/{count} answers
	// 200 with an empty list, which looks like a working server right up until
	// the numbers are compared against the file.
	data, err := os.ReadFile(path)
	if err != nil {
		log.Printf("dataset %s: %v", path, err)
		return
	}
	if err := sonic.Unmarshal(data, &dataset); err != nil {
		log.Printf("dataset %s: %v", path, err)
	}
}

// sonic compiles an encoder per type the first time it meets it. Doing that
// here, once per worker at startup, keeps the compile out of the first
// requests of a run - the JIT is the point of choosing it, so pay for it
// where nothing is being measured.
func pretouchJSON() {
	for _, t := range []reflect.Type{
		reflect.TypeOf(ProcessResponse{}),
		reflect.TypeOf(itemsResponse{}),
		reflect.TypeOf(fiber.Map{}),
		reflect.TypeOf(crudBody{}),
	} {
		if err := sonic.Pretouch(t); err != nil {
			log.Printf("sonic pretouch %s: %v", t, err)
		}
	}
}

func pipeline(c fiber.Ctx) error {
	return c.SendString("ok")
}

// The profile sends a and b and nothing else, so they are read by name through
// Fiber's typed query binder rather than materialising the whole query string
// into a map. Both are hot: baseline drives this endpoint at 4096 connections
// and latency-1m and latency-10k score what a request costs in CPU, where one
// map allocation per request is a line item.
func baseline11(c fiber.Ctx) error {
	sum := fiber.Query[int](c, "a") + fiber.Query[int](c, "b")
	if c.Method() == fiber.MethodPost {
		if n, err := strconv.Atoi(strings.TrimSpace(string(c.Body()))); err == nil {
			sum += n
		}
	}
	return c.SendString(strconv.Itoa(sum))
}

// The longest wait this will serve. The profile asks for 10ms and validation
// for at most half a second; the cap is here because time.Duration(ms) *
// time.Millisecond overflows int64 past about 292 years' worth of milliseconds,
// and an overflowed duration is negative, so the handler answers immediately -
// the one answer this endpoint is not allowed to give.
const maxDelayMillis = int(time.Hour / time.Millisecond)

// GET /delay/{ms}: answer no earlier than the wait named in the path. A
// goroutine parked on a timer is what Fiber gives you for free here - the
// handler blocks, the process does not.
func delay(c fiber.Ctx) error {
	ms := fiber.Params[int](c, "ms", -1)
	if ms < 0 || ms > maxDelayMillis {
		return c.SendStatus(fiber.StatusNotFound)
	}
	if ms > 0 {
		time.Sleep(time.Duration(ms) * time.Millisecond)
	}
	return c.SendString(strconv.Itoa(ms))
}

func jsonItems(c fiber.Ctx) error {
	count := fiber.Params[int](c, "count", 0)
	if count < 0 {
		count = 0
	}
	if count > len(dataset) {
		count = len(dataset)
	}
	// An explicit m=0 reads as "not given", the same as an absent or unparsable
	// one. Every entry in the repo does this and the profiles only ever send
	// m >= 1, so the alternative is a column of zero totals that nothing asks
	// for and that no other row would report.
	m := fiber.Query[int](c, "m", 1)
	if m == 0 {
		m = 1
	}

	items := make([]ProcessedItem, count)
	for i := 0; i < count; i++ {
		d := dataset[i]
		items[i] = ProcessedItem{DatasetItem: d, Total: d.Price * d.Quantity * m}
	}
	return c.JSON(ProcessResponse{Items: items, Count: count})
}

func echoBody(c fiber.Ctx) error {
	// fasthttp has already read the body, chunked or not, so the echo is the
	// buffer it holds -- Send sets Content-Length from it.
	c.Set(fiber.HeaderContentType, "application/octet-stream")
	return c.Send(c.Body())
}

var pgPool *pgxpool.Pool
var rdb *redis.Client

const itemColumns = "id, name, category, price, quantity, active, tags, rating_score, rating_count"

// The crud routes read and write the same ids, so a long TTL would answer from
// a copy the writes have already moved past. No profile drives them any more;
// the TTL is kept at what the workload they were built for needed.
const crudTTL = 200 * time.Millisecond

// The pool is sized from DATABASE_MAX_CONN, as in the standard entry. Tuned
// mode allows "custom pool sizes", but the number is the server's, not this
// entry's: a pool larger than what Postgres accepts is a pool that fails to
// fill, and a smaller one gives connections away.
//
// The 8 subtracted below is a safety margin rather than an exact figure: the
// server keeps 3 connections back for the superuser by default, and the
// harness's own psql and pg_isready probes want one now and then. The remainder
// is divided by the worker count because the budget belongs to the container,
// not to a process, and every child opens a pool of its own against the same
// server - undivided, the fleet would ask for sixty-four times what it can get.
//
// What is tuned is when the connections are opened. pgxpool opens them lazily,
// so in the standard entry the first requests of a run pay for a TCP connect
// and a Postgres handshake each. MinConns set to the pool size has the pool
// open them at startup instead, in a goroutine, before load arrives.
func loadPgPool() {
	url := os.Getenv("DATABASE_URL")
	if url == "" {
		return
	}
	cfg, err := pgxpool.ParseConfig(url)
	if err != nil {
		log.Printf("database url: %v", err)
		return
	}
	budget := 256
	if v := os.Getenv("DATABASE_MAX_CONN"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			budget = n
		}
	}
	workers := workerProcesses()
	maxConns := (budget - 8) / workers
	if maxConns < 1 {
		maxConns = 1
	}
	cfg.MaxConns = int32(maxConns)
	cfg.MinConns = int32(maxConns)
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
		log.Printf("database pool: %v", err)
		return
	}
	pgPool = pool
}

func loadRedis() {
	url := os.Getenv("REDIS_URL")
	if url == "" {
		return
	}
	opt, err := redis.ParseURL(url)
	if err != nil {
		log.Printf("redis url: %v", err)
		return
	}
	rdb = redis.NewClient(opt)
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
			return nil, err
		}
		if len(tags) > 0 {
			if err := sonic.Unmarshal(tags, &it.Tags); err != nil {
				return nil, err
			}
		}
		if it.Tags == nil {
			it.Tags = []string{}
		}
		items = append(items, it)
	}
	// A connection that fails mid-iteration ends the loop like a clean finish
	// does. Without this the handler would answer 200 with however many rows
	// arrived before the error, which reads as a short result rather than a
	// failed one.
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return items, nil
}

func clamp(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

// The async-db response is a struct rather than a fiber.Map: same JSON, without
// asking encoding/json to reflect over a map and sort its keys per request.
type itemsResponse struct {
	Items []DatasetItem `json:"items"`
	Count int           `json:"count"`
}

var emptyItems = itemsResponse{Items: []DatasetItem{}}

// Every database and cache call is answered inside this deadline.
//
// Fiber's Ctx.Context() is a background context unless the application puts one
// there, and fasthttp has no per-request cancellation to put there either - a
// client that walks away mid-query leaves the query running and its pool
// connection held. A deadline is what bounds that, and it is what the net/http
// entries get from the request context for free.
const dbTimeout = 5 * time.Second

func dbContext() (context.Context, context.CancelFunc) {
	return context.WithTimeout(context.Background(), dbTimeout)
}

func asyncDb(c fiber.Ctx) error {
	if pgPool == nil {
		return c.JSON(emptyItems)
	}
	ctx, cancel := dbContext()
	defer cancel()
	items, err := queryItems(ctx,
		"SELECT "+itemColumns+" FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
		fiber.Query[int](c, "min", 10), fiber.Query[int](c, "max", 50),
		clamp(fiber.Query[int](c, "limit", 50), 1, 50))
	// An empty list rather than a 500: it is the shape the profile documents and
	// what every other entry answers here. It does mean a database that is down
	// reads the same as a price range with nothing in it - validation tells them
	// apart, because it asserts count == limit on ranges that do have rows.
	if err != nil {
		return c.JSON(emptyItems)
	}
	return c.JSON(itemsResponse{Items: items, Count: len(items)})
}

func crudList(c fiber.Ctx) error {
	if pgPool == nil {
		return c.Status(500).JSON(fiber.Map{"error": "DB not available"})
	}
	category := c.Query("category")
	if category == "" {
		category = "electronics"
	}
	page := fiber.Query[int](c, "page", 1)
	if page < 1 {
		page = 1
	}
	limit := clamp(fiber.Query[int](c, "limit", 10), 1, 50)
	ctx, cancel := dbContext()
	defer cancel()
	items, err := queryItems(ctx,
		"SELECT "+itemColumns+" FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3",
		category, limit, (page-1)*limit)
	if err != nil {
		return c.Status(500).JSON(fiber.Map{"error": "query failed"})
	}
	return c.JSON(fiber.Map{"items": items, "total": len(items), "page": page, "limit": limit})
}

type crudBody struct {
	ID       int    `json:"id"`
	Name     string `json:"name"`
	Category string `json:"category"`
	Price    int    `json:"price"`
	Quantity int    `json:"quantity"`
}

func crudCreate(c fiber.Ctx) error {
	if pgPool == nil {
		return c.Status(500).JSON(fiber.Map{"error": "DB not available"})
	}
	var b crudBody
	if err := sonic.Unmarshal(c.Body(), &b); err != nil {
		return c.Status(500).JSON(fiber.Map{"error": "insert failed"})
	}
	if b.Name == "" {
		b.Name = "New Product"
	}
	if b.Category == "" {
		b.Category = "test"
	}
	ctx, cancel := dbContext()
	defer cancel()
	var id int
	err := pgPool.QueryRow(ctx,
		`INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count)
		 VALUES ($1, $2, $3, $4, $5, true, '["bench"]', 0, 0)
		 ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5 RETURNING id`,
		b.ID, b.Name, b.Category, b.Price, b.Quantity).Scan(&id)
	if err != nil {
		return c.Status(500).JSON(fiber.Map{"error": "insert failed"})
	}
	// ON CONFLICT makes this an upsert, so it can move a row a previous read
	// already cached. Same invalidation the update path does.
	if rdb != nil {
		rdb.Del(ctx, "crud:"+strconv.Itoa(id))
	}
	return c.Status(201).JSON(fiber.Map{"id": id, "name": b.Name,
		"category": b.Category, "price": b.Price, "quantity": b.Quantity})
}

// Cache-aside on Redis where a REDIS_URL is provided. Nothing in a single
// container run provides one - the harness passes it only to the compose
// stacks - so in practice this reads straight through to Postgres.
func crudRead(c fiber.Ctx) error {
	if pgPool == nil {
		return c.Status(500).JSON(fiber.Map{"error": "DB not available"})
	}
	id := fiber.Params[int](c, "id", -1)
	if id < 0 {
		return c.SendStatus(fiber.StatusNotFound)
	}
	ctx, cancel := dbContext()
	defer cancel()
	key := "crud:" + strconv.Itoa(id)
	if rdb != nil {
		if hit, err := rdb.Get(ctx, key).Result(); err == nil && hit != "" {
			c.Set("X-Cache", "HIT")
			c.Set("Content-Type", "application/json")
			return c.SendString(hit)
		}
	}
	items, err := queryItems(ctx, "SELECT "+itemColumns+" FROM items WHERE id = $1 LIMIT 1", id)
	if err != nil {
		return c.Status(500).JSON(fiber.Map{"error": "query failed"})
	}
	if len(items) == 0 {
		return c.SendStatus(404)
	}
	body, _ := sonic.Marshal(items[0])
	if rdb != nil {
		rdb.Set(ctx, key, body, crudTTL)
	}
	c.Set("X-Cache", "MISS")
	c.Set("Content-Type", "application/json")
	return c.Send(body)
}

func crudUpdate(c fiber.Ctx) error {
	if pgPool == nil {
		return c.Status(500).JSON(fiber.Map{"error": "DB not available"})
	}
	id := fiber.Params[int](c, "id", -1)
	if id < 0 {
		return c.SendStatus(fiber.StatusNotFound)
	}
	var b crudBody
	if err := sonic.Unmarshal(c.Body(), &b); err != nil {
		return c.Status(500).JSON(fiber.Map{"error": "update failed"})
	}
	if b.Name == "" {
		b.Name = "Updated"
	}
	ctx, cancel := dbContext()
	defer cancel()
	tag, err := pgPool.Exec(ctx,
		"UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4",
		b.Name, b.Price, b.Quantity, id)
	if err != nil {
		return c.Status(500).JSON(fiber.Map{"error": "update failed"})
	}
	if tag.RowsAffected() == 0 {
		return c.SendStatus(404)
	}
	if rdb != nil {
		rdb.Del(ctx, "crud:"+strconv.Itoa(id))
	}
	return c.JSON(fiber.Map{"id": id, "name": b.Name, "price": b.Price, "quantity": b.Quantity})
}

var mimeTypes = map[string]string{
	".css": "text/css", ".js": "application/javascript", ".html": "text/html",
	".woff2": "font/woff2", ".svg": "image/svg+xml", ".webp": "image/webp",
	".json": "application/json",
}

// What the static profiles require is that the response follow the disk:
// replace a file and the next response carries the new bytes. Serving from
// memory is allowed in every mode, but only through a cache that is the
// framework's own - so this reads per request and holds no copy of its own.
//
// Fiber's own static middleware is not an option for either half of that.
// Its cache holds open file handles and never re-stats them, so a file replaced
// on disk keeps being served for up to CacheDuration - which is the one thing
// the profile checks. And its Compress option generates .fiber.br twins next to
// the originals rather than reading the .br/.gz ones already there, on a
// directory the harness mounts read-only.
//
// So the twins are picked up here. The profile allows selecting them off
// Accept-Encoding where a framework has no API of its own for it; those bytes
// exist on disk either way, which makes this a file read rather than
// compression. It is also the difference between answering the 20-file rotation
// with the 1.21 MB the originals weigh and the 318 KB the twins do, because the
// compress middleware sits this round out: fasthttp's Accept-Encoding matcher
// compares whole tokens, and the profile sends "br;q=1, gzip;q=0.8".
func staticFile(c fiber.Ctx) error {
	name := c.Params("filename")
	if name == "" || strings.Contains(name, "/") || strings.Contains(name, "..") {
		return c.SendStatus(fiber.StatusNotFound)
	}
	path := "/data/static/" + name

	var data []byte
	enc := ""
	// Fiber's own negotiation reads the q-values the way RFC 9110 says, which
	// is the whole difficulty here. It is guarded on the header being present
	// because with no Accept-Encoding at all a negotiator answers with the
	// first offer, and that would encode a body for a client that never asked.
	if c.Get(fiber.HeaderAcceptEncoding) != "" {
		switch c.AcceptsEncodings("br", "gzip") {
		case "br":
			if b, err := os.ReadFile(path + ".br"); err == nil {
				data, enc = b, "br"
			}
		case "gzip":
			if b, err := os.ReadFile(path + ".gz"); err == nil {
				data, enc = b, "gzip"
			}
		}
	}
	if enc == "" {
		b, err := os.ReadFile(path)
		if err != nil {
			return c.SendStatus(fiber.StatusNotFound)
		}
		data = b
	}

	// The Content-Type is the original file's either way; only the encoding
	// changes. Set before Send so the compress middleware sees a body that is
	// already encoded and leaves it alone.
	ct := mimeTypes[filepath.Ext(name)]
	if ct == "" {
		ct = "application/octet-stream"
	}
	c.Set(fiber.HeaderContentType, ct)
	if enc != "" {
		c.Set(fiber.HeaderContentEncoding, enc)
		c.Set(fiber.HeaderVary, fiber.HeaderAcceptEncoding)
	}
	return c.Send(data)
}

func main() {
	// The master process supervises children and nothing else: it binds no
	// socket and serves no request, so the dataset, the pool and the cache
	// client belong in the children. Each of those re-runs main() from the top
	// with the marker environment variable set, which is what fiber.IsChild
	// reads - and loading the pool there rather than here is also what keeps a
	// live connection out of the process that forks.
	serving := fiber.IsChild()
	if serving {
		loadDataset()
		loadPgPool()
		loadRedis()
		pretouchJSON()
	}

	// The one Config the standard entry does without. sonic replaces
	// encoding/json behind c.JSON - tuned mode names alternative serializers
	// first among what it allows - and it is the JIT build, not the compat
	// one: on amd64 and arm64 sonic's build tags select it for every Go from
	// 1.17 up to, not including, 1.28. Its output for these types is the same
	// bytes encoding/json writes; the one default that differs, HTML escaping,
	// has nothing to act on in the dataset. Everything else in Config stays at
	// the framework's default, the 4 MB body limit included.
	app := fiber.New(fiber.Config{
		JSONEncoder: sonic.Marshal,
		JSONDecoder: sonic.Unmarshal,
	})

	// Compression is mounted on the two routes with a body worth compressing
	// rather than on the whole app, as in the standard entry. The level is
	// what differs: best speed rather than the default. json-comp scores
	// requests per second for a body that is serialized and compressed per
	// request, and the profile requires valid gzip or brotli, not a ratio -
	// the compress middleware picks brotli for the profile's "gzip, br", so
	// this is brotli level 0 instead of fasthttp's default 4, and gzip level 1
	// instead of 6 for a client that accepts only gzip. On a sandbox core the
	// brotli step for the 8.4 KB /json/50 body is ~259 us at the default on
	// the release's library, ~107 us at the default on go-brrr, and ~26 us at
	// level 0 on go-brrr, at 1490 -> 1944 bytes on the wire. Static is
	// unaffected either way: the twins on disk are compressed already, and the
	// middleware leaves an encoded body alone.
	app.Use([]string{"/json", "/static"}, compress.New(compress.Config{
		Level: compress.LevelBestSpeed,
	}))

	app.Get("/pipeline", pipeline)
	app.Get("/baseline11", baseline11)
	app.Post("/baseline11", baseline11)
	app.Get("/json/:count", jsonItems)
	app.Post("/echo", echoBody)
	app.Get("/baseline2", baseline11)
	app.Get("/delay/:ms", delay)
	app.Get("/static/:filename", staticFile)
	app.Get("/async-db", asyncDb)
	app.Get("/crud/items", crudList)
	app.Post("/crud/items", crudCreate)
	app.Get("/crud/items/:id", crudRead)
	app.Put("/crud/items/:id", crudUpdate)

	listen := fiber.ListenConfig{
		DisableStartupMessage: true,
		EnablePrefork:         true,
	}

	var signalled context.Context
	if serving {
		// A worker signalled directly finishes the requests it is holding
		// before it exits. That is the path fasthttp's own prefork teardown
		// takes: when the master stops supervising it SIGTERMs its children and
		// waits for them.
		//
		// The waiting has to happen here rather than in ListenConfig's
		// GracefulContext, which shuts the listener down in a goroutine while
		// Listen returns straight away - main then exits and takes the
		// in-flight response with it. Measured: with the wait below a request
		// signalled 0.4s into a 1.5s handler still answers 200 at 1.5s; without
		// it the client's connection dies at 0.4s.
		//
		// `docker stop` is a different path and does not drain: it signals
		// PID 1, which in this container is the prefork master. The master
		// serves nothing and deliberately holds no handler of its own - taking
		// the signal over from the runtime there would keep it alive until
		// Docker gave up waiting and escalated to SIGKILL - so it exits, and
		// the kernel kills the workers with it, PID 1 of a namespace taking the
		// namespace with it.
		ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
		defer stop()
		signalled = ctx
		drained = make(chan struct{})
		go func() {
			<-ctx.Done()
			// Inside the 5s the prefork master waits for a signalled child
			// before it kills it (PreforkShutdownGracePeriod), so a handler
			// that will not finish cannot turn a teardown into a SIGKILL.
			if err := app.ShutdownWithTimeout(shutdownGrace); err != nil {
				log.Printf("shutdown: %v", err)
			}
			close(drained)
		}()

		// json-tls, static-tls and 8gbit on 8081, the same app behind TLS. The
		// harness mounts /certs for every run, so the files being there is what
		// says the listener is wanted.
		const cert, key = "/certs/server.crt", "/certs/server.key"
		_, certErr := os.Stat(cert)
		_, keyErr := os.Stat(key)
		if certErr == nil && keyErr == nil {
			// The keypair is loaded here rather than handed to Fiber as
			// CertFile/CertKeyFile, because that path installs a TLSHandler
			// whose GetCertificate callback writes the ClientHello onto one
			// shared struct on every handshake, unsynchronised (fiber
			// ctx.go:95-98, wired at listen.go:233-241). `go build -race`
			// reports it as a data race under concurrent handshakes, and the
			// three profiles on this port drive 512 to 16384 connections.
			// Nothing here reads that ClientHello. Passing TLSConfig takes the
			// branch that clones the config as given and installs no handler;
			// the fields are the ones Fiber's own CertFile path would have set.
			// NextProtos stays unset, as it is on that path and in go-fasthttp:
			// the profile's TLS probe accepts a server that omits ALPN ("none
			// negotiated, client falls back"), and a server advertising only
			// http/1.1 would answer a client that offers only h2 with a failed
			// handshake, where omitting the extension lets it fall back.
			pair, pairErr := tls.LoadX509KeyPair(cert, key)
			if pairErr != nil {
				log.Printf("tls keypair: %v", pairErr)
			} else {
				go func() {
					// In a child, EnablePrefork means "take the SO_REUSEPORT socket
					// for this address", not "fork again": fasthttp checks the
					// child marker before it looks at anything else. Without it
					// every worker would race for an ordinary bind on 8081 and all
					// but one would lose it - silently, back when this dropped the
					// error instead of logging it.
					err := app.Listen(":8081", fiber.ListenConfig{
						DisableStartupMessage: true,
						EnablePrefork:         true,
						TLSConfig: &tls.Config{
							MinVersion:   tls.VersionTLS12,
							Certificates: []tls.Certificate{pair},
						},
					})
					if err != nil {
						log.Printf("tls listener on :8081: %v", err)
					}
				}()
			}
		}
	}

	err := app.Listen(":8080", listen)

	// Listen returns for two reasons, and they need opposite answers. After a
	// signal it means the shutdown started, and the process has to stay up
	// until the drain finishes. Otherwise the listener failed - or, in the
	// master, prefork gave up replacing children - and the container should
	// exit rather than sit there answering nothing.
	if signalled == nil || signalled.Err() == nil {
		if err != nil {
			log.Printf("listener on :8080: %v", err)
		}
		os.Exit(1)
	}
	<-drained
}
