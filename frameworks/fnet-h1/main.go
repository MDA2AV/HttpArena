package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	_ "net/http/pprof"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/andybalholm/brotli"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/linfeip/fnet"
	"github.com/linfeip/fnet/fhttp"
	"github.com/redis/go-redis/v9"
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

// router dispatches on the request path with a switch instead of through
// http.ServeMux. The routes are a fixed handful, so the switch is a few
// comparisons where the mux walks its pattern trees; it also hands each
// handler its path parameter as a plain substring (the count of /json/{count},
// the delay of /delay/{ms}) rather than having the mux resolve it into
// Request.PathValue. Both matter per request: this Handler runs on every
// request of the baseline, pipelined, limited-conn, json-comp and async
// profiles.
//
// The answers match what the mux gave: GET and HEAD are served by the same
// handlers (HEAD keeps the Content-Length, fhttp drops the body), a known path
// with any other method is 405 with Allow, and anything else is 404.
type router struct{}

func (router) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch p := r.URL.Path; p {
	case "/baseline11", "/baseline2": // /baseline2 is the short alias of the readiness probes
		switch r.Method {
		case http.MethodGet, http.MethodHead, http.MethodPost:
			baseline11(w, r)
		default:
			methodNotAllowed(w, "GET, HEAD, POST")
		}
	case "/pipeline":
		switch r.Method {
		case http.MethodGet, http.MethodHead:
			pipeline(w)
		default:
			methodNotAllowed(w, "GET, HEAD")
		}
	case "/echo":
		if r.Method != http.MethodPost {
			methodNotAllowed(w, "POST")
			return
		}
		echoBody(w, r)
	case "/static", "/static/":
		http.NotFound(w, r)
	case "/async-db":
		switch r.Method {
		case http.MethodGet, http.MethodHead:
			asyncDb(w, r)
		default:
			methodNotAllowed(w, "GET, HEAD")
		}
	case "/crud/items":
		switch r.Method {
		case http.MethodGet, http.MethodHead:
			crudList(w, r)
		case http.MethodPost:
			crudCreate(w, r)
		default:
			methodNotAllowed(w, "GET, HEAD, POST")
		}
	default:
		if name, ok := strings.CutPrefix(p, "/static/"); ok && isSegment(name) {
			if r.Method != http.MethodGet && r.Method != http.MethodHead {
				methodNotAllowed(w, "GET, HEAD")
				return
			}
			staticFile(w, r, name)
			return
		}
		if rest, ok := strings.CutPrefix(p, "/crud/items/"); ok && isSegment(rest) {
			switch r.Method {
			case http.MethodGet, http.MethodHead:
				crudRead(w, r, rest)
			case http.MethodPut:
				crudUpdate(w, r, rest)
			default:
				methodNotAllowed(w, "GET, HEAD, PUT")
			}
			return
		}
		if count, ok := strings.CutPrefix(p, "/json/"); ok && isSegment(count) {
			if r.Method != http.MethodGet && r.Method != http.MethodHead {
				methodNotAllowed(w, "GET, HEAD")
				return
			}
			jsonItems(w, r, count)
			return
		}
		if ms, ok := strings.CutPrefix(p, "/delay/"); ok && isSegment(ms) {
			if r.Method != http.MethodGet && r.Method != http.MethodHead {
				methodNotAllowed(w, "GET, HEAD")
				return
			}
			delay(w, ms)
			return
		}
		http.NotFound(w, r)
	}
}

// isSegment reports whether s is one non-empty path segment, which is all a
// single {name} wildcard of the mux matched: "/json/" and "/json/25/" are not
// routes.
func isSegment(s string) bool {
	return s != "" && !strings.Contains(s, "/")
}

func methodNotAllowed(w http.ResponseWriter, allow string) {
	w.Header().Set("Allow", allow)
	w.WriteHeader(http.StatusMethodNotAllowed)
}

// baseline11 sums every integer query parameter, plus the integer body of a
// POST. The query is walked in place: r.URL.Query would build a map of all of
// it for a Handler that only adds the values up, an allocation per request.
func baseline11(w http.ResponseWriter, r *http.Request) {
	sum := 0
	fhttp.ForEachQuery(r, func(_, value string) bool {
		if n, err := strconv.Atoi(value); err == nil {
			sum += n
		}
		return true
	})
	if r.Method == http.MethodPost {
		body, err := fhttp.RequestBody(r) // the buffered body itself, not a copy
		if err == nil {
			sum += atoi(body)
		}
	}
	writeSum(w, sum)
}

// writeSum writes sum as text/plain, formatting it into a stack buffer so that
// nothing of the response is allocated.
func writeSum(w http.ResponseWriter, sum int) {
	w.Header().Set("Content-Type", "text/plain")
	var buf [24]byte
	w.Write(strconv.AppendInt(buf[:0], int64(sum), 10))
}

func pipeline(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/plain")
	io.WriteString(w, "ok") // fhttp's response has WriteString: the literal is not copied
}

func delay(w http.ResponseWriter, msStr string) {
	ms, err := strconv.Atoi(msStr)
	if err != nil || ms < 0 {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	if ms > 0 {
		time.Sleep(time.Duration(ms) * time.Millisecond)
	}
	writeSum(w, ms)
}

// jsonItems serializes the first count items per request. When the client
// accepts gzip or brotli the response is compressed; fhttp has no compression
// middleware of its own, so the standard library's gzip and the established
// brotli library do the encoding the client asked for.
func jsonItems(w http.ResponseWriter, r *http.Request, countStr string) {
	count, _ := strconv.Atoi(countStr)
	if count < 0 {
		count = 0
	}
	if count > len(dataset) {
		count = len(dataset)
	}
	m, err := strconv.Atoi(fhttp.QueryParam(r, "m")) // like URL.Query().Get without the map
	if err != nil || m == 0 {
		m = 1
	}

	items := make([]ProcessedItem, count)
	for i := 0; i < count; i++ {
		d := dataset[i]
		items[i] = ProcessedItem{DatasetItem: d, Total: d.Price * d.Quantity * m}
	}
	body, err := json.Marshal(ProcessResponse{Items: items, Count: count})
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		return
	}

	switch acceptedEncoding(r) {
	case "br":
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Content-Encoding", "br")
		bw := brotliWriters.Get().(*brotli.Writer)
		bw.Reset(w)
		_, _ = bw.Write(body)
		_ = bw.Close()
		brotliWriters.Put(bw)
	case "gzip":
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Content-Encoding", "gzip")
		gw := gzipWriters.Get().(*gzip.Writer)
		gw.Reset(w)
		_, _ = gw.Write(body)
		_ = gw.Close()
		gzipWriters.Put(gw)
	default:
		w.Header().Set("Content-Type", "application/json")
		w.Write(body)
	}
}

// Compression writers are pooled, and the levels match what fasthttp's
// CompressHandlerBrotliLevel uses by default (brotli quality 4, gzip 6), so
// the json-comp comparison measures the same work on both sides. Creating a
// brotli writer per request allocates its encoder state every time and drops
// json-comp to a few tens of thousands of requests per second.
var (
	brotliWriters = sync.Pool{New: func() any {
		return brotli.NewWriterLevel(io.Discard, 4)
	}}
	gzipWriters = sync.Pool{New: func() any { return gzip.NewWriter(io.Discard) }}
)

// acceptedEncoding returns the encoding to answer with: "gzip" or "br", or ""
// when the request accepts neither. At equal q values gzip wins, because the
// two produce nearly identical bodies on these payloads (1490 vs 1519 bytes
// for /json/50?m=6) while brotli quality 4 costs several times gzip's CPU - on
// json-comp it is 76% of the server's samples against flate's 31% on the
// gzip-only entries. A client that asks for brotli by q value still gets it.
func acceptedEncoding(r *http.Request) string {
	header := r.Header.Get("Accept-Encoding")
	if header == "" {
		return ""
	}
	var gzipQ, brotliQ float64
	for header != "" {
		var part string
		part, header, _ = strings.Cut(header, ",")
		name := strings.TrimSpace(part)
		q := 1.0
		if i := strings.IndexByte(name, ';'); i >= 0 {
			params := name[i+1:]
			name = strings.TrimSpace(name[:i])
			for params != "" {
				var param string
				param, params, _ = strings.Cut(params, ";")
				param = strings.TrimSpace(param)
				if v, ok := strings.CutPrefix(param, "q="); ok {
					if f, err := strconv.ParseFloat(strings.TrimSpace(v), 64); err == nil {
						q = f
					}
				}
			}
		}
		switch strings.ToLower(name) {
		case "gzip":
			gzipQ = q
		case "br":
			brotliQ = q
		}
	}
	switch {
	case gzipQ > 0 && gzipQ >= brotliQ:
		return "gzip"
	case brotliQ > 0:
		return "br"
	}
	return ""
}

// mimeTypes is the Content-Type of each extension the static profile serves.
// Anything else goes out as application/octet-stream.
var mimeTypes = map[string]string{
	".css": "text/css", ".js": "application/javascript", ".html": "text/html",
	".woff2": "font/woff2", ".svg": "image/svg+xml", ".webp": "image/webp",
	".json": "application/json",
}

// staticFile answers GET /static/{name} from the directory the harness mounts
// at /data/static. The file is read on every request, which the static profiles
// require in every mode: the response has to follow the disk, so a cache of the
// bytes would fail the staleness probe.
//
// The pre-compressed .br/.gz twins that sit next to the originals are served
// when the client accepts that encoding. Those bytes already exist on disk, so
// this is a file read rather than the compression the profile reserves for the
// framework's own middleware, and it is also what answers the 20-file rotation
// in 318 KB instead of 1.2 MB.
func staticFile(w http.ResponseWriter, r *http.Request, name string) {
	if strings.Contains(name, "..") {
		http.NotFound(w, r)
		return
	}
	path := "/data/static/" + name

	enc := ""
	var data []byte
	switch acceptedEncoding(r) {
	case "br":
		if b, err := os.ReadFile(path + ".br"); err == nil {
			data, enc = b, "br"
		}
	case "gzip":
		if b, err := os.ReadFile(path + ".gz"); err == nil {
			data, enc = b, "gzip"
		}
	}
	if enc == "" {
		b, err := os.ReadFile(path)
		if err != nil {
			http.NotFound(w, r)
			return
		}
		data = b
	}

	// The variant is chosen off Accept-Encoding, so every answer varies on it.
	// The Content-Type is the original file's either way; only the encoding
	// changes. The length is declared because fhttp otherwise streams a body
	// over 64KB in chunks, and a static file has its length in hand.
	h := w.Header()
	h.Set("Vary", "Accept-Encoding")
	ct := mimeTypes[filepath.Ext(name)]
	if ct == "" {
		ct = "application/octet-stream"
	}
	h.Set("Content-Type", ct)
	if enc != "" {
		h.Set("Content-Encoding", enc)
	}
	h.Set("Content-Length", strconv.Itoa(len(data)))
	w.Write(data)
}

func echoBody(w http.ResponseWriter, r *http.Request) {
	body, err := fhttp.RequestBody(r)
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Write(body)
}

// atoi parses the integer in b as strconv.Atoi on its string would, returning 0
// where Atoi returns an error; a body of up to 18 digits is summed in place, so
// the common case allocates nothing.
func atoi(b []byte) int {
	b = bytes.TrimSpace(b)
	if len(b) == 0 || len(b) > 18 {
		n, err := strconv.Atoi(string(b))
		if err != nil {
			return 0
		}
		return n
	}
	n := 0
	for _, c := range b {
		if c < '0' || c > '9' { // a sign or anything else: let strconv judge it
			v, err := strconv.Atoi(string(b))
			if err != nil {
				return 0
			}
			return v
		}
		n = n*10 + int(c-'0')
	}
	return n
}

// ---------- async-db and crud ----------

// pgPool is built once in main, before any server exists, and only read
// afterwards: no mutex. rdb is nil unless the harness provides REDIS_URL.
var (
	pgPool *pgxpool.Pool
	rdb    *redis.Client
)

const itemColumns = "id, name, category, price, quantity, active, tags, rating_score, rating_count"

// crud reads and writes the same ids, so a long TTL would answer from a copy
// the writes have already moved past.
const crudTTL = 200 * time.Millisecond

// dbTimeout bounds every database and cache call made for one request. The
// request context already ends when the client leaves, but a client that stays
// connected through a stalled query would otherwise hold a pool connection for
// as long as it likes.
const dbTimeout = 5 * time.Second

// loadPgPool sizes the pool from DATABASE_MAX_CONN, as the async-db profile
// requires, less the margin Postgres keeps for its superuser and the harness's
// own probes. Unlike fiber, which divides that budget over its prefork children,
// this entry is a single process - the budget is the whole pool's - so the
// margin is only the handful of connections Postgres reserves.
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
	maxConns := budget - 8
	if maxConns < 1 {
		maxConns = 1
	}
	cfg.MaxConns = int32(maxConns)
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

func pool() *pgxpool.Pool { return pgPool }

// queryItems reads items rows. tags is a JSONB column, so it comes back as
// bytes rather than a Go slice.
func queryItems(ctx context.Context, p *pgxpool.Pool, sql string, args ...any) ([]DatasetItem, error) {
	rows, err := p.Query(ctx, sql, args...)
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
			if err := json.Unmarshal(tags, &it.Tags); err != nil {
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

// queryInt reads an integer query parameter, falling back when it is absent or
// unparsable. fhttp.QueryParam walks the raw query without the map URL.Query
// builds.
func queryInt(r *http.Request, name string, fallback int) int {
	if v := fhttp.QueryParam(r, name); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return fallback
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

// writeJSON writes v with its Content-Length declared. fhttp would buffer a
// body under 64KB and work the length out itself; declaring it saves that step
// and is what the crud and async-db callers read.
func writeJSON(w http.ResponseWriter, status int, v any) {
	body, err := json.Marshal(v)
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	h := w.Header()
	h.Set("Content-Type", "application/json")
	h.Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(status)
	w.Write(body)
}

// The response shapes are structs rather than maps: same JSON, without asking
// encoding/json to sort the keys of a map on every request.
type itemsResponse struct {
	Items []DatasetItem `json:"items"`
	Count int           `json:"count"`
}

type crudListResponse struct {
	Items []DatasetItem `json:"items"`
	Total int           `json:"total"`
	Page  int           `json:"page"`
	Limit int           `json:"limit"`
}

type crudItemResponse struct {
	ID       int    `json:"id"`
	Name     string `json:"name"`
	Category string `json:"category"`
	Price    int    `json:"price"`
	Quantity int    `json:"quantity"`
}

type crudUpdateResponse struct {
	ID       int    `json:"id"`
	Name     string `json:"name"`
	Price    int    `json:"price"`
	Quantity int    `json:"quantity"`
}

// The empty answer, spelled out: an itemsResponse with a nil Items slice would
// marshal as {"items":null,"count":0}, and the profile documents a list.
var emptyItems = `{"items":[],"count":0}`

func writeEmptyItems(w http.ResponseWriter) {
	h := w.Header()
	h.Set("Content-Type", "application/json")
	h.Set("Content-Length", strconv.Itoa(len(emptyItems)))
	w.Write([]byte(emptyItems))
}

// asyncDb answers GET /async-db?min=&max=&limit= with a range scan over the
// items table. An unavailable database and an empty range both answer with the
// empty list, which is the shape the profile documents.
func asyncDb(w http.ResponseWriter, r *http.Request) {
	p := pool()
	if p == nil {
		writeEmptyItems(w)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), dbTimeout)
	defer cancel()
	items, err := queryItems(ctx, p,
		"SELECT "+itemColumns+" FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
		queryInt(r, "min", 10), queryInt(r, "max", 50),
		clamp(queryInt(r, "limit", 50), 1, 50))
	if err != nil {
		writeEmptyItems(w)
		return
	}
	writeJSON(w, http.StatusOK, itemsResponse{Items: items, Count: len(items)})
}

func dbUnavailable(w http.ResponseWriter) {
	writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "DB not available"})
}

func dbQueryFailed(w http.ResponseWriter) {
	writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "query failed"})
}

func crudList(w http.ResponseWriter, r *http.Request) {
	p := pool()
	if p == nil {
		dbUnavailable(w)
		return
	}
	category := fhttp.QueryParam(r, "category")
	if category == "" {
		category = "electronics"
	}
	page := queryInt(r, "page", 1)
	if page < 1 {
		page = 1
	}
	limit := clamp(queryInt(r, "limit", 10), 1, 50)
	ctx, cancel := context.WithTimeout(r.Context(), dbTimeout)
	defer cancel()
	items, err := queryItems(ctx, p,
		"SELECT "+itemColumns+" FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3",
		category, limit, (page-1)*limit)
	if err != nil {
		dbQueryFailed(w)
		return
	}
	writeJSON(w, http.StatusOK, crudListResponse{Items: items, Total: len(items), Page: page, Limit: limit})
}

type crudBody struct {
	ID       int    `json:"id"`
	Name     string `json:"name"`
	Category string `json:"category"`
	Price    int    `json:"price"`
	Quantity int    `json:"quantity"`
}

// readCrudBody parses the request body. fhttp hands a buffered body back
// without a copy, so this is the bytes as they arrived.
func readCrudBody(r *http.Request) (crudBody, error) {
	var b crudBody
	body, err := fhttp.RequestBody(r)
	if err != nil {
		return b, err
	}
	err = json.Unmarshal(body, &b)
	return b, err
}

func crudCreate(w http.ResponseWriter, r *http.Request) {
	p := pool()
	if p == nil {
		dbUnavailable(w)
		return
	}
	b, err := readCrudBody(r)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "insert failed"})
		return
	}
	if b.Name == "" {
		b.Name = "New Product"
	}
	if b.Category == "" {
		b.Category = "test"
	}
	ctx, cancel := context.WithTimeout(r.Context(), dbTimeout)
	defer cancel()
	var id int
	err = p.QueryRow(ctx,
		`INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count)
		 VALUES ($1, $2, $3, $4, $5, true, '["bench"]', 0, 0)
		 ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5 RETURNING id`,
		b.ID, b.Name, b.Category, b.Price, b.Quantity).Scan(&id)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "insert failed"})
		return
	}
	// ON CONFLICT makes this an upsert, so it can move a row a previous read
	// already cached: same invalidation the update path does.
	if rdb != nil {
		rdb.Del(ctx, "crud:"+strconv.Itoa(id))
	}
	writeJSON(w, http.StatusCreated, crudItemResponse{ID: id, Name: b.Name,
		Category: b.Category, Price: b.Price, Quantity: b.Quantity})
}

// crudRead is cache-aside on Redis where a REDIS_URL is provided. Nothing in a
// single container run provides one, so in practice this reads straight
// through to Postgres.
func crudRead(w http.ResponseWriter, r *http.Request, idStr string) {
	p := pool()
	if p == nil {
		dbUnavailable(w)
		return
	}
	id, err := strconv.Atoi(idStr)
	if err != nil || id < 0 {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), dbTimeout)
	defer cancel()
	key := "crud:" + strconv.Itoa(id)
	if rdb != nil {
		if hit, err := rdb.Get(ctx, key).Result(); err == nil && hit != "" {
			h := w.Header()
			h.Set("Content-Type", "application/json")
			h.Set("Content-Length", strconv.Itoa(len(hit)))
			h.Set("X-Cache", "HIT")
			w.Write([]byte(hit))
			return
		}
	}
	items, err := queryItems(ctx, p, "SELECT "+itemColumns+" FROM items WHERE id = $1 LIMIT 1", id)
	if err != nil {
		dbQueryFailed(w)
		return
	}
	if len(items) == 0 {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	body, err := json.Marshal(items[0])
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		return
	}
	if rdb != nil {
		rdb.Set(ctx, key, body, crudTTL)
	}
	h := w.Header()
	h.Set("Content-Type", "application/json")
	h.Set("Content-Length", strconv.Itoa(len(body)))
	h.Set("X-Cache", "MISS")
	w.Write(body)
}

func crudUpdate(w http.ResponseWriter, r *http.Request, idStr string) {
	p := pool()
	if p == nil {
		dbUnavailable(w)
		return
	}
	id, err := strconv.Atoi(idStr)
	if err != nil || id < 0 {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	b, err := readCrudBody(r)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "update failed"})
		return
	}
	if b.Name == "" {
		b.Name = "Updated"
	}
	ctx, cancel := context.WithTimeout(r.Context(), dbTimeout)
	defer cancel()
	tag, err := p.Exec(ctx,
		"UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4",
		b.Name, b.Price, b.Quantity, id)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]string{"error": "update failed"})
		return
	}
	if tag.RowsAffected() == 0 {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	if rdb != nil {
		rdb.Del(ctx, "crud:"+strconv.Itoa(id))
	}
	writeJSON(w, http.StatusOK, crudUpdateResponse{ID: id, Name: b.Name, Price: b.Price, Quantity: b.Quantity})
}

func main() {
	loadDataset()
	loadPgPool()
	loadRedis()

	// Opt-in profiling: off unless PPROF_ADDR is set, so the measured version
	// is the same code either way. PPROF_BLOCK additionally turns on block and
	// mutex sampling, which is what shows waiting (not just burning CPU).
	if pprofAddr := os.Getenv("PPROF_ADDR"); pprofAddr != "" {
		if os.Getenv("PPROF_BLOCK") != "" {
			runtime.SetBlockProfileRate(100000) // sample blocking events >= 100µs
			runtime.SetMutexProfileFraction(100)
		}
		go func() {
			if err := http.ListenAndServe(pprofAddr, nil); err != nil {
				log.Printf("pprof listener %s: %v", pprofAddr, err)
			}
		}()
	}

	addr := os.Getenv("FNET_H1_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	// ReusePort gives every loop a listening socket of its own, sharing the
	// port through SO_REUSEPORT, so on Linux the kernel spreads the
	// connections over the loops instead of feeding them from one listener.
	// NoDelay is off unless FNET_H1_NODELAY is set, so the default entry
	// keeps fnet's default Nagle behaviour.
	engine := fnet.Options{ReusePort: true, NoDelay: os.Getenv("FNET_H1_NODELAY") != ""}
	server, err := fhttp.NewServer(addr, router{}, fhttp.Options{Engine: engine})
	if err != nil {
		log.Fatal(err)
	}

	// json-tls, static-tls and 8gbit on 8081, the same routes behind TLS. The
	// harness mounts /certs only for the profiles that need it, so the files
	// being there is what says the listener is wanted. fhttp takes h2 out of
	// the ALPN protocols it offers (see its Options.TLSConfig), leaving
	// http/1.1, which is what those profiles ask for.
	//
	// The handshake runs inside fnet's connection callbacks, so a TLS
	// connection costs no goroutine of its own - and, unlike fiber's prefork
	// children, this server can simply be a second fhttp.Server on the same
	// engine options.
	var tlsServer *fhttp.Server
	if pair, ok := loadTLSKeyPair(); ok {
		tlsAddr := os.Getenv("FNET_H1_TLS_ADDR")
		if tlsAddr == "" {
			tlsAddr = ":8081"
		}
		tlsServer, err = fhttp.NewServer(tlsAddr, router{}, fhttp.Options{
			Engine: engine,
			TLSConfig: &tls.Config{
				MinVersion:   tls.VersionTLS12,
				Certificates: []tls.Certificate{pair},
			},
		})
		if err != nil {
			log.Printf("tls listener %s: %v", tlsAddr, err)
		} else {
			go func() {
				if err := tlsServer.Serve(); err != nil && !errors.Is(err, http.ErrServerClosed) {
					log.Printf("tls listener %s: %v", tlsAddr, err)
				}
			}()
		}
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-stop
		if tlsServer != nil {
			_ = tlsServer.Close()
		}
		_ = server.Close()
	}()

	if err := server.Serve(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}

// loadTLSKeyPair reads the pair the harness mounts at /certs. /certs is
// mounted for every run, not only the TLS profiles, so a readable pair says
// nothing about whether port 8081 is wanted - but it costs a second server that
// serves the same routes over TLS, which is harmless for an entry that has no
// TLS test, and it is what lets this entry pick up json-tls, static-tls and
// 8gbit without another switch to forget.
func loadTLSKeyPair() (tls.Certificate, bool) {
	const cert, key = "/certs/server.crt", "/certs/server.key"
	if _, err := os.Stat(cert); err != nil {
		return tls.Certificate{}, false
	}
	if _, err := os.Stat(key); err != nil {
		return tls.Certificate{}, false
	}
	pair, err := tls.LoadX509KeyPair(cert, key)
	if err != nil {
		log.Printf("tls keypair: %v", err)
		return tls.Certificate{}, false
	}
	return pair, true
}
