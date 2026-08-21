package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"database/sql"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"github.com/valyala/fasthttp"
	"github.com/valyala/fasthttp/reuseport"
	_ "modernc.org/sqlite"
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
	ID       int      `json:"id"`
	Name     string   `json:"name"`
	Category string   `json:"category"`
	Price    int      `json:"price"`
	Quantity int      `json:"quantity"`
	Active   bool     `json:"active"`
	Tags     []string `json:"tags"`
	Rating   Rating   `json:"rating"`
	Total    int      `json:"total"`
}

type ProcessResponse struct {
	Items []ProcessedItem `json:"items"`
	Count int             `json:"count"`
}

var dataset []DatasetItem
var db *sql.DB
var pgPool *pgxpool.Pool

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

func baseline11Handler(ctx *fasthttp.RequestCtx) {
	args := ctx.QueryArgs()
	a := args.GetUintOrZero("a")
	b := args.GetUintOrZero("b")
	sum := a + b

	body := ctx.PostBody()
	if len(body) > 0 {
		if n, err := strconv.Atoi(string(body)); err == nil {
			sum += n
		}
	}

	ctx.Response.Header.Set("Server", "go-fasthttp")
	ctx.SetContentType("text/plain")
	ctx.SetBodyString(strconv.Itoa(sum))
}

func pipelineHandler(ctx *fasthttp.RequestCtx) {
	ctx.Response.Header.Set("Server", "go-fasthttp")
	ctx.SetContentType("text/plain")
	ctx.SetBodyString("ok")
}

func processHandler(ctx *fasthttp.RequestCtx, count int) {
	if count > len(dataset) {
		count = len(dataset)
	}
	if count < 0 {
		count = 0
	}

	m, _ := strconv.Atoi(string(ctx.QueryArgs().Peek("m")))
	if m == 0 {
		m = 1
	}

	items := make([]ProcessedItem, count)
	for i := 0; i < count; i++ {
		d := dataset[i]
		items[i] = ProcessedItem{
			ID:       d.ID,
			Name:     d.Name,
			Category: d.Category,
			Price:    d.Price,
			Quantity: d.Quantity,
			Active:   d.Active,
			Tags:     d.Tags,
			Rating:   d.Rating,
			Total:    d.Price * d.Quantity * m,
		}
	}

	resp := ProcessResponse{Items: items, Count: count}
	ctx.Response.Header.Set("Server", "go-fasthttp")
	ctx.SetContentType("application/json")
	body, _ := json.Marshal(resp)

	ae := string(ctx.Request.Header.Peek("Accept-Encoding"))
	if strings.Contains(ae, "gzip") {
		var buf bytes.Buffer
		gz := gzip.NewWriter(&buf)
		gz.Write(body)
		gz.Close()
		ctx.Response.Header.Set("Content-Encoding", "gzip")
		ctx.SetBody(buf.Bytes())
	} else {
		ctx.SetBody(body)
	}
}

func loadDB() {
	if _, err := os.Stat("/data/benchmark.db"); err != nil {
		return
	}
	d, err := sql.Open("sqlite", "file:/data/benchmark.db?mode=ro&immutable=1")
	if err != nil {
		return
	}
	d.SetMaxOpenConns(runtime.NumCPU())
	d.SetMaxIdleConns(runtime.NumCPU())
	db = d
}

func loadPgPool() {
	dbURL := os.Getenv("DATABASE_URL")
	if dbURL == "" {
		return
	}
	config, err := pgxpool.ParseConfig(dbURL)
	if err != nil {
		return
	}
	config.MaxConns = int32(runtime.NumCPU() * 4)
	pool, err := pgxpool.NewWithConfig(context.Background(), config)
	if err != nil {
		return
	}
	pgPool = pool
}

func asyncDbHandler(ctx *fasthttp.RequestCtx) {
	if pgPool == nil {
		ctx.Response.Header.Set("Server", "go-fasthttp")
		ctx.SetContentType("application/json")
		ctx.SetBodyString(`{"items":[],"count":0}`)
		return
	}
	minPrice := 10
	maxPrice := 50
	limit := 50
	if v := ctx.QueryArgs().Peek("min"); len(v) > 0 {
		if n, err := strconv.Atoi(string(v)); err == nil {
			minPrice = n
		}
	}
	if v := ctx.QueryArgs().Peek("max"); len(v) > 0 {
		if n, err := strconv.Atoi(string(v)); err == nil {
			maxPrice = n
		}
	}
	if v := ctx.QueryArgs().Peek("limit"); len(v) > 0 {
		if n, err := strconv.Atoi(string(v)); err == nil {
			limit = n
			if limit < 1 {
				limit = 1
			}
			if limit > 50 {
				limit = 50
			}
		}
	}
	rows, err := pgPool.Query(context.Background(), "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3", minPrice, maxPrice, limit)
	if err != nil {
		ctx.Response.Header.Set("Server", "go-fasthttp")
		ctx.SetContentType("application/json")
		ctx.SetBodyString(`{"items":[],"count":0}`)
		return
	}
	defer rows.Close()
	var items []map[string]interface{}
	for rows.Next() {
		var id, quantity, ratingCount int
		var name, category string
		var price, ratingScore int
		var active bool
		var tags []byte
		if err := rows.Scan(&id, &name, &category, &price, &quantity, &active, &tags, &ratingScore, &ratingCount); err != nil {
			continue
		}
		var tagsArr []interface{}
		json.Unmarshal(tags, &tagsArr)
		items = append(items, map[string]interface{}{
			"id": id, "name": name, "category": category,
			"price": price, "quantity": quantity, "active": active,
			"tags":   tagsArr,
			"rating": map[string]interface{}{"score": ratingScore, "count": ratingCount},
		})
	}
	if items == nil {
		items = []map[string]interface{}{}
	}
	resp := map[string]interface{}{"items": items, "count": len(items)}
	ctx.Response.Header.Set("Server", "go-fasthttp")
	ctx.SetContentType("application/json")
	body, _ := json.Marshal(resp)
	ctx.SetBody(body)
}

func uploadHandler(ctx *fasthttp.RequestCtx) {
	body := ctx.PostBody()
	ctx.Response.Header.Set("Server", "go-fasthttp")
	ctx.SetContentType("text/plain")
	ctx.SetBodyString(strconv.Itoa(len(body)))
}

func dbHandler(ctx *fasthttp.RequestCtx) {
	if db == nil {
		ctx.SetStatusCode(500)
		ctx.SetBodyString("DB not available")
		return
	}
	minPrice := 10.0
	maxPrice := 50.0
	if v := ctx.QueryArgs().Peek("min"); len(v) > 0 {
		if f, err := strconv.ParseFloat(string(v), 64); err == nil {
			minPrice = f
		}
	}
	if v := ctx.QueryArgs().Peek("max"); len(v) > 0 {
		if f, err := strconv.ParseFloat(string(v), 64); err == nil {
			maxPrice = f
		}
	}
	rows, err := db.Query("SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50", minPrice, maxPrice)
	if err != nil {
		ctx.SetStatusCode(500)
		ctx.SetBodyString("Query failed")
		return
	}
	defer rows.Close()
	var items []map[string]interface{}
	for rows.Next() {
		var id, quantity, active, ratingCount int
		var name, category, tags string
		var price, ratingScore int
		if err := rows.Scan(&id, &name, &category, &price, &quantity, &active, &tags, &ratingScore, &ratingCount); err != nil {
			continue
		}
		var tagsArr []string
		json.Unmarshal([]byte(tags), &tagsArr)
		items = append(items, map[string]interface{}{
			"id": id, "name": name, "category": category,
			"price": price, "quantity": quantity, "active": active == 1,
			"tags":   tagsArr,
			"rating": map[string]interface{}{"score": ratingScore, "count": ratingCount},
		})
	}
	resp := map[string]interface{}{"items": items, "count": len(items)}
	ctx.Response.Header.Set("Server", "go-fasthttp")
	ctx.SetContentType("application/json")
	body, _ := json.Marshal(resp)
	ctx.SetBody(body)
}

var rdb *redis.Client

const itemColumns = "id, name, category, price, quantity, active, tags, rating_score, rating_count"

// The crud profile reads and writes the same ids, so a long TTL would answer
// from a copy the writes have already moved past.
const crudTTL = 200 * time.Millisecond

func loadRedis() {
	url := os.Getenv("REDIS_URL")
	if url == "" {
		return
	}
	opt, err := redis.ParseURL(url)
	if err != nil {
		return
	}
	rdb = redis.NewClient(opt)
}

// tags is a JSONB column, so it comes back as bytes rather than a Go slice.
func queryItems(ctx context.Context, sql string, args ...any) ([]map[string]any, error) {
	rows, err := pgPool.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []map[string]any{}
	for rows.Next() {
		var id, quantity, price, ratingScore, ratingCount int
		var name, category string
		var active bool
		var tags []byte
		if err := rows.Scan(&id, &name, &category, &price, &quantity, &active,
			&tags, &ratingScore, &ratingCount); err != nil {
			continue
		}
		var tagsArr []any
		json.Unmarshal(tags, &tagsArr)
		if tagsArr == nil {
			tagsArr = []any{}
		}
		items = append(items, map[string]any{
			"id": id, "name": name, "category": category,
			"price": price, "quantity": quantity, "active": active,
			"tags":   tagsArr,
			"rating": map[string]any{"score": ratingScore, "count": ratingCount},
		})
	}
	return items, nil
}

func queryIntArg(ctx *fasthttp.RequestCtx, name string, fallback int) int {
	if v := ctx.QueryArgs().Peek(name); len(v) > 0 {
		if n, err := strconv.Atoi(string(v)); err == nil {
			return n
		}
	}
	return fallback
}

func clampInt(v, lo, hi int) int {
	if v < lo {
		return lo
	}
	if v > hi {
		return hi
	}
	return v
}

func writeJSONCtx(ctx *fasthttp.RequestCtx, status int, v any) {
	body, _ := json.Marshal(v)
	ctx.Response.Header.Set("Server", "go-fasthttp")
	ctx.SetStatusCode(status)
	ctx.SetContentType("application/json")
	ctx.SetBody(body)
}

func crudListHandler(ctx *fasthttp.RequestCtx) {
	if pgPool == nil {
		writeJSONCtx(ctx, 500, map[string]any{"error": "DB not available"})
		return
	}
	category := string(ctx.QueryArgs().Peek("category"))
	if category == "" {
		category = "electronics"
	}
	page := queryIntArg(ctx, "page", 1)
	if page < 1 {
		page = 1
	}
	limit := clampInt(queryIntArg(ctx, "limit", 10), 1, 50)
	items, err := queryItems(context.Background(),
		"SELECT "+itemColumns+" FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3",
		category, limit, (page-1)*limit)
	if err != nil {
		writeJSONCtx(ctx, 500, map[string]any{"error": "query failed"})
		return
	}
	writeJSONCtx(ctx, 200, map[string]any{
		"items": items, "total": len(items), "page": page, "limit": limit})
}

type crudBody struct {
	ID       int    `json:"id"`
	Name     string `json:"name"`
	Category string `json:"category"`
	Price    int    `json:"price"`
	Quantity int    `json:"quantity"`
}

func crudCreateHandler(ctx *fasthttp.RequestCtx) {
	if pgPool == nil {
		writeJSONCtx(ctx, 500, map[string]any{"error": "DB not available"})
		return
	}
	var b crudBody
	if err := json.Unmarshal(ctx.PostBody(), &b); err != nil {
		writeJSONCtx(ctx, 500, map[string]any{"error": "insert failed"})
		return
	}
	if b.Name == "" {
		b.Name = "New Product"
	}
	if b.Category == "" {
		b.Category = "test"
	}
	var id int
	err := pgPool.QueryRow(context.Background(),
		`INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count)
		 VALUES ($1, $2, $3, $4, $5, true, '["bench"]', 0, 0)
		 ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5 RETURNING id`,
		b.ID, b.Name, b.Category, b.Price, b.Quantity).Scan(&id)
	if err != nil {
		writeJSONCtx(ctx, 500, map[string]any{"error": "insert failed"})
		return
	}
	writeJSONCtx(ctx, 201, map[string]any{"id": id, "name": b.Name,
		"category": b.Category, "price": b.Price, "quantity": b.Quantity})
}

// Cache-aside on Redis where the harness provides it - crud is the one profile
// that does.
func crudReadHandler(ctx *fasthttp.RequestCtx, id int) {
	if pgPool == nil {
		writeJSONCtx(ctx, 500, map[string]any{"error": "DB not available"})
		return
	}
	bg := context.Background()
	key := "crud:" + strconv.Itoa(id)
	if rdb != nil {
		if hit, err := rdb.Get(bg, key).Result(); err == nil && hit != "" {
			ctx.Response.Header.Set("Server", "go-fasthttp")
			ctx.Response.Header.Set("X-Cache", "HIT")
			ctx.SetContentType("application/json")
			ctx.SetBodyString(hit)
			return
		}
	}
	items, err := queryItems(bg, "SELECT "+itemColumns+" FROM items WHERE id = $1 LIMIT 1", id)
	if err != nil {
		writeJSONCtx(ctx, 500, map[string]any{"error": "query failed"})
		return
	}
	if len(items) == 0 {
		ctx.SetStatusCode(404)
		return
	}
	body, _ := json.Marshal(items[0])
	if rdb != nil {
		rdb.Set(bg, key, body, crudTTL)
	}
	ctx.Response.Header.Set("Server", "go-fasthttp")
	ctx.Response.Header.Set("X-Cache", "MISS")
	ctx.SetContentType("application/json")
	ctx.SetBody(body)
}

func crudUpdateHandler(ctx *fasthttp.RequestCtx, id int) {
	if pgPool == nil {
		writeJSONCtx(ctx, 500, map[string]any{"error": "DB not available"})
		return
	}
	var b crudBody
	if err := json.Unmarshal(ctx.PostBody(), &b); err != nil {
		writeJSONCtx(ctx, 500, map[string]any{"error": "update failed"})
		return
	}
	if b.Name == "" {
		b.Name = "Updated"
	}
	bg := context.Background()
	tag, err := pgPool.Exec(bg,
		"UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4",
		b.Name, b.Price, b.Quantity, id)
	if err != nil {
		writeJSONCtx(ctx, 500, map[string]any{"error": "update failed"})
		return
	}
	if tag.RowsAffected() == 0 {
		ctx.SetStatusCode(404)
		return
	}
	if rdb != nil {
		rdb.Del(bg, "crud:"+strconv.Itoa(id))
	}
	writeJSONCtx(ctx, 200, map[string]any{"id": id, "name": b.Name,
		"price": b.Price, "quantity": b.Quantity})
}

var mimeTypes = map[string]string{
	".css": "text/css", ".js": "application/javascript", ".html": "text/html",
	".woff2": "font/woff2", ".svg": "image/svg+xml", ".webp": "image/webp",
	".json": "application/json",
}

// Static bodies are read from disk on every request. fasthttp.FS, which this
// used before, keeps small files in an in-memory cache and writes its own
// compressed copies next to the originals - the static profiles forbid holding
// file bodies in memory in every mode.
func staticHandler(ctx *fasthttp.RequestCtx, name string) {
	if name == "" || strings.Contains(name, "/") || strings.Contains(name, "..") {
		ctx.SetStatusCode(404)
		return
	}
	base := "/data/static/" + name
	path, enc := base, ""
	ae := string(ctx.Request.Header.Peek("Accept-Encoding"))
	if strings.Contains(ae, "br") {
		if _, err := os.Stat(base + ".br"); err == nil {
			path, enc = base+".br", "br"
		}
	}
	if enc == "" && strings.Contains(ae, "gzip") {
		if _, err := os.Stat(base + ".gz"); err == nil {
			path, enc = base+".gz", "gzip"
		}
	}
	data, err := os.ReadFile(path)
	if err != nil {
		ctx.SetStatusCode(404)
		return
	}
	ct := mimeTypes[filepath.Ext(name)]
	if ct == "" {
		ct = "application/octet-stream"
	}
	ctx.Response.Header.Set("Server", "go-fasthttp")
	ctx.SetContentType(ct)
	if enc != "" {
		ctx.Response.Header.Set("Content-Encoding", enc)
		ctx.Response.Header.Set("Vary", "Accept-Encoding")
	}
	ctx.SetBody(data)
}

func main() {
	loadDataset()
	loadDB()
	loadPgPool()
	loadRedis()

	handler := func(ctx *fasthttp.RequestCtx) {
		method := string(ctx.Method())

		if method != "GET" && method != "POST" && method != "PUT" {
			ctx.SetStatusCode(fasthttp.StatusMethodNotAllowed)
			return
		}

		path := string(ctx.Path())
		switch {
		case path == "/pipeline":
			pipelineHandler(ctx)
		case strings.HasPrefix(path, "/json/"):
			count, _ := strconv.Atoi(path[len("/json/"):])
			processHandler(ctx, count)
		case path == "/upload":
			uploadHandler(ctx)
		case path == "/db":
			dbHandler(ctx)
		case path == "/async-db":
			asyncDbHandler(ctx)
		case strings.HasPrefix(path, "/static/"):
			staticHandler(ctx, path[len("/static/"):])
		case path == "/crud/items":
			if method == "POST" {
				crudCreateHandler(ctx)
			} else {
				crudListHandler(ctx)
			}
		case strings.HasPrefix(path, "/crud/items/"):
			id, err := strconv.Atoi(path[len("/crud/items/"):])
			if err != nil {
				ctx.SetStatusCode(404)
			} else if method == "PUT" {
				crudUpdateHandler(ctx, id)
			} else {
				crudReadHandler(ctx, id)
			}
		case strings.HasPrefix(path, "/baseline"):
			baseline11Handler(ctx)
		default:
			ctx.SetStatusCode(fasthttp.StatusNotFound)
		}
	}
	// json-tls and static-tls on 8081, the same handler behind TLS. The harness
	// only mounts /certs for the TLS profiles, so without them it is not opened.
	const cert, key = "/certs/server.crt", "/certs/server.key"
	tlsEnabled := false
	if _, err := os.Stat(cert); err == nil {
		if _, err := os.Stat(key); err == nil {
			tlsEnabled = true
		}
	}

	numCPU := runtime.NumCPU()
	var wg sync.WaitGroup
	for i := 0; i < numCPU; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ln, err := reuseport.Listen("tcp4", ":8080")
			if err != nil {
				log.Fatal(err)
			}
			s := &fasthttp.Server{
				Handler:            handler,
				MaxRequestBodySize: 25 * 1024 * 1024, // 25 MB
			}
			s.Serve(ln)
		}()
		// Every worker binds 8081 too, so the TLS listener is spread across the
		// same set of processes rather than parked on one.
		if tlsEnabled {
			wg.Add(1)
			go func() {
				defer wg.Done()
				ln, err := reuseport.Listen("tcp4", ":8081")
				if err != nil {
					return
				}
				s := &fasthttp.Server{
					Handler:            handler,
					MaxRequestBodySize: 25 * 1024 * 1024,
				}
				s.ServeTLS(ln, cert, key)
			}()
		}
	}
	wg.Wait()
}
