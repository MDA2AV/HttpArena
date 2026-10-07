package main

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/0mjs/zinc"
	"github.com/0mjs/zinc/middleware/compress"
	"github.com/jackc/pgx/v5/pgxpool"
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

func pipeline(c *zinc.Context) error {
	return c.String("ok")
}

// Sleeping the goroutine is the idiomatic wait here: the runtime parks it and reuses the
// thread, so the waits in flight are bounded by memory rather than by OS threads.
func delay(c *zinc.Context) error {
	ms, err := strconv.Atoi(c.Param("ms"))
	if err != nil || ms < 0 {
		return c.Status(http.StatusNotFound).NoContent()
	}
	if ms > 0 {
		time.Sleep(time.Duration(ms) * time.Millisecond)
	}
	return c.String(strconv.Itoa(ms))
}

func baseline11(c *zinc.Context) error {
	sum := 0
	for _, values := range c.QueryValues() {
		for _, v := range values {
			if n, err := strconv.Atoi(v); err == nil {
				sum += n
			}
		}
	}
	if c.Request().Method == http.MethodPost {
		body, err := io.ReadAll(c.Request().Body)
		if err == nil {
			if n, err := strconv.Atoi(strings.TrimSpace(string(body))); err == nil {
				sum += n
			}
		}
	}
	return c.String(strconv.Itoa(sum))
}

func jsonItems(c *zinc.Context) error {
	count, _ := strconv.Atoi(c.Param("count"))
	if count < 0 {
		count = 0
	}
	if count > len(dataset) {
		count = len(dataset)
	}
	m, err := strconv.Atoi(c.Query("m"))
	if err != nil || m == 0 {
		m = 1
	}

	items := make([]ProcessedItem, count)
	for i := 0; i < count; i++ {
		d := dataset[i]
		items[i] = ProcessedItem{DatasetItem: d, Total: d.Price * d.Quantity * m}
	}
	return c.JSON(ProcessResponse{Items: items, Count: count})
}

func echoBody(c *zinc.Context) error {
	// Read the whole body before writing: net/http closes the request body once
	// response headers flush with unread body left (maxPostHandlerReadBytes =
	// 256 KB), which would truncate a 100 KB echo.
	body, err := io.ReadAll(c.Request().Body)
	if err != nil {
		return c.Status(http.StatusBadRequest).NoContent()
	}
	return c.Data("application/octet-stream", body)
}

var pgPool *pgxpool.Pool
var rdb *redis.Client

const itemColumns = "id, name, category, price, quantity, active, tags, rating_score, rating_count"

// The crud profile reads and writes the same ids, so a long TTL would answer
// from a copy the writes have already moved past.
const crudTTL = 200 * time.Millisecond

// One process here, so the whole connection budget is ours - but Postgres runs
// with max_connections=256 and reserves a few of those for the superuser.
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
	maxConns := budget - 8
	if m := runtime.NumCPU() * 4; m < maxConns {
		maxConns = m
	}
	if maxConns < 1 {
		maxConns = 1
	}
	cfg.MaxConns = int32(maxConns)
	pool, err := pgxpool.NewWithConfig(context.Background(), cfg)
	if err != nil {
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
			continue
		}
		json.Unmarshal(tags, &it.Tags)
		if it.Tags == nil {
			it.Tags = []string{}
		}
		items = append(items, it)
	}
	return items, nil
}

func queryInt(c *zinc.Context, name string, fallback int) int {
	if v := c.Query(name); v != "" {
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

var emptyItems = map[string]any{"items": []DatasetItem{}, "count": 0}

func asyncDb(c *zinc.Context) error {
	if pgPool == nil {
		return c.JSON(emptyItems)
	}
	items, err := queryItems(c.Request().Context(),
		"SELECT "+itemColumns+" FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
		queryInt(c, "min", 10), queryInt(c, "max", 50), clamp(queryInt(c, "limit", 50), 1, 50))
	if err != nil {
		return c.JSON(emptyItems)
	}
	return c.JSON(map[string]any{"items": items, "count": len(items)})
}

func crudList(c *zinc.Context) error {
	if pgPool == nil {
		return c.Status(http.StatusInternalServerError).JSON(map[string]any{"error": "DB not available"})
	}
	category := c.Query("category")
	if category == "" {
		category = "electronics"
	}
	page := queryInt(c, "page", 1)
	if page < 1 {
		page = 1
	}
	limit := clamp(queryInt(c, "limit", 10), 1, 50)
	items, err := queryItems(c.Request().Context(),
		"SELECT "+itemColumns+" FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3",
		category, limit, (page-1)*limit)
	if err != nil {
		return c.Status(http.StatusInternalServerError).JSON(map[string]any{"error": "query failed"})
	}
	return c.JSON(map[string]any{
		"items": items, "total": len(items), "page": page, "limit": limit})
}

type crudBody struct {
	ID       int    `json:"id"`
	Name     string `json:"name"`
	Category string `json:"category"`
	Price    int    `json:"price"`
	Quantity int    `json:"quantity"`
}

func crudCreate(c *zinc.Context) error {
	if pgPool == nil {
		return c.Status(http.StatusInternalServerError).JSON(map[string]any{"error": "DB not available"})
	}
	var b crudBody
	if err := c.Bind().JSON(&b); err != nil {
		return c.Status(http.StatusInternalServerError).JSON(map[string]any{"error": "insert failed"})
	}
	if b.Name == "" {
		b.Name = "New Product"
	}
	if b.Category == "" {
		b.Category = "test"
	}
	var id int
	err := pgPool.QueryRow(c.Request().Context(),
		`INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count)
		 VALUES ($1, $2, $3, $4, $5, true, '["bench"]', 0, 0)
		 ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5 RETURNING id`,
		b.ID, b.Name, b.Category, b.Price, b.Quantity).Scan(&id)
	if err != nil {
		return c.Status(http.StatusInternalServerError).JSON(map[string]any{"error": "insert failed"})
	}
	return c.Status(http.StatusCreated).JSON(map[string]any{"id": id, "name": b.Name,
		"category": b.Category, "price": b.Price, "quantity": b.Quantity})
}

// Cache-aside on Redis where the harness provides it - crud is the one profile
// that does.
func crudRead(c *zinc.Context) error {
	if pgPool == nil {
		return c.Status(http.StatusInternalServerError).JSON(map[string]any{"error": "DB not available"})
	}
	id, err := strconv.Atoi(c.Param("id"))
	if err != nil {
		return c.Status(http.StatusNotFound).NoContent()
	}
	ctx := c.Request().Context()
	key := "crud:" + strconv.Itoa(id)
	if rdb != nil {
		if hit, err := rdb.Get(ctx, key).Result(); err == nil && hit != "" {
			c.SetHeader("X-Cache", "HIT")
			return c.Data("application/json", []byte(hit))
		}
	}
	items, err := queryItems(ctx, "SELECT "+itemColumns+" FROM items WHERE id = $1 LIMIT 1", id)
	if err != nil {
		return c.Status(http.StatusInternalServerError).JSON(map[string]any{"error": "query failed"})
	}
	if len(items) == 0 {
		return c.Status(http.StatusNotFound).NoContent()
	}
	body, _ := json.Marshal(items[0])
	if rdb != nil {
		rdb.Set(ctx, key, body, crudTTL)
	}
	c.SetHeader("X-Cache", "MISS")
	return c.Data("application/json", body)
}

func crudUpdate(c *zinc.Context) error {
	if pgPool == nil {
		return c.Status(http.StatusInternalServerError).JSON(map[string]any{"error": "DB not available"})
	}
	id, err := strconv.Atoi(c.Param("id"))
	if err != nil {
		return c.Status(http.StatusNotFound).NoContent()
	}
	var b crudBody
	if err := c.Bind().JSON(&b); err != nil {
		return c.Status(http.StatusInternalServerError).JSON(map[string]any{"error": "update failed"})
	}
	if b.Name == "" {
		b.Name = "Updated"
	}
	ctx := c.Request().Context()
	tag, err := pgPool.Exec(ctx,
		"UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4",
		b.Name, b.Price, b.Quantity, id)
	if err != nil {
		return c.Status(http.StatusInternalServerError).JSON(map[string]any{"error": "update failed"})
	}
	if tag.RowsAffected() == 0 {
		return c.Status(http.StatusNotFound).NoContent()
	}
	if rdb != nil {
		rdb.Del(ctx, "crud:"+strconv.Itoa(id))
	}
	return c.JSON(map[string]any{"id": id, "name": b.Name,
		"price": b.Price, "quantity": b.Quantity})
}

var mimeTypes = map[string]string{
	".css": "text/css", ".js": "application/javascript", ".html": "text/html",
	".woff2": "font/woff2", ".svg": "image/svg+xml", ".webp": "image/webp",
	".json": "application/json",
}

// Static bodies are read from disk on every request, which the static profiles
// require in every mode. Standard mode leaves the encoding to the compress
// middleware mounted above rather than serving a pre-compressed sibling.
func staticFile(c *zinc.Context) error {
	name := c.Param("filename")
	if name == "" || strings.Contains(name, "/") || strings.Contains(name, "..") {
		return c.Status(http.StatusNotFound).NoContent()
	}
	data, err := os.ReadFile("/data/static/" + name)
	if err != nil {
		return c.Status(http.StatusNotFound).NoContent()
	}
	ct := mimeTypes[filepath.Ext(name)]
	if ct == "" {
		ct = "application/octet-stream"
	}
	return c.Data(ct, data)
}

func main() {
	loadDataset()
	loadPgPool()
	loadRedis()

	app := zinc.New()
	app.Use(compress.New())

	app.Get("/pipeline", pipeline)
	app.Get("/delay/{ms}", delay)
	app.Get("/baseline11", baseline11)
	app.Post("/baseline11", baseline11)
	app.Get("/json/{count}", jsonItems)
	app.Post("/echo", echoBody)
	app.Get("/baseline2", baseline11)
	app.Get("/static/{filename}", staticFile)
	app.Get("/async-db", asyncDb)
	app.Get("/crud/items", crudList)
	app.Post("/crud/items", crudCreate)
	app.Get("/crud/items/{id}", crudRead)
	app.Put("/crud/items/{id}", crudUpdate)

	// json-tls and static-tls on 8081, and baseline-h2 and static-h2 on 8443:
	// the same app behind TLS, where net/http negotiates HTTP/2 by ALPN. The
	// harness only mounts /certs for the TLS profiles, so without them neither
	// is opened.
	const cert, key = "/certs/server.crt", "/certs/server.key"
	if _, err := os.Stat(cert); err == nil {
		if _, err := os.Stat(key); err == nil {
			go app.ListenTLS(":8081", cert, key)
			go (&http.Server{Addr: ":8443", Handler: app}).ListenAndServeTLS(cert, key)
		}
	}

	// baseline-h2c and json-h2c on 8082: an App is an http.Handler, so a
	// standard server with unencrypted HTTP/2 serves it.
	h2c := new(http.Protocols)
	h2c.SetHTTP1(true)
	h2c.SetUnencryptedHTTP2(true)
	go (&http.Server{Addr: ":8082", Handler: app, Protocols: h2c}).ListenAndServe()

	if err := app.Listen(":8080"); err != nil {
		os.Stderr.WriteString(err.Error() + "\n")
		os.Exit(1)
	}
}
