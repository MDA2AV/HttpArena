package main

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/gofiber/fiber/v3"
	"github.com/gofiber/fiber/v3/middleware/compress"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
)

const maxBody = 25 * 1024 * 1024

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

func pipeline(c fiber.Ctx) error {
	return c.SendString("ok")
}

func baseline11(c fiber.Ctx) error {
	sum := 0
	for _, v := range c.Queries() {
		if n, err := strconv.Atoi(v); err == nil {
			sum += n
		}
	}
	if c.Method() == fiber.MethodPost {
		if n, err := strconv.Atoi(strings.TrimSpace(string(c.Body()))); err == nil {
			sum += n
		}
	}
	return c.SendString(strconv.Itoa(sum))
}

func jsonItems(c fiber.Ctx) error {
	count, _ := strconv.Atoi(c.Params("count"))
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

func upload(c fiber.Ctx) error {
	return c.SendString(strconv.Itoa(len(c.Body())))
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

func queryInt(c fiber.Ctx, name string, fallback int) int {
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

var emptyItems = fiber.Map{"items": []DatasetItem{}, "count": 0}

func asyncDb(c fiber.Ctx) error {
	if pgPool == nil {
		return c.JSON(emptyItems)
	}
	items, err := queryItems(c.Context(),
		"SELECT "+itemColumns+" FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
		queryInt(c, "min", 10), queryInt(c, "max", 50), clamp(queryInt(c, "limit", 50), 1, 50))
	if err != nil {
		return c.JSON(emptyItems)
	}
	return c.JSON(fiber.Map{"items": items, "count": len(items)})
}

func crudList(c fiber.Ctx) error {
	if pgPool == nil {
		return c.Status(500).JSON(fiber.Map{"error": "DB not available"})
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
	items, err := queryItems(c.Context(),
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
	if err := json.Unmarshal(c.Body(), &b); err != nil {
		return c.Status(500).JSON(fiber.Map{"error": "insert failed"})
	}
	if b.Name == "" {
		b.Name = "New Product"
	}
	if b.Category == "" {
		b.Category = "test"
	}
	var id int
	err := pgPool.QueryRow(c.Context(),
		`INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count)
		 VALUES ($1, $2, $3, $4, $5, true, '["bench"]', 0, 0)
		 ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5 RETURNING id`,
		b.ID, b.Name, b.Category, b.Price, b.Quantity).Scan(&id)
	if err != nil {
		return c.Status(500).JSON(fiber.Map{"error": "insert failed"})
	}
	return c.Status(201).JSON(fiber.Map{"id": id, "name": b.Name,
		"category": b.Category, "price": b.Price, "quantity": b.Quantity})
}

// Cache-aside on Redis where the harness provides it - crud is the one profile
// that does.
func crudRead(c fiber.Ctx) error {
	if pgPool == nil {
		return c.Status(500).JSON(fiber.Map{"error": "DB not available"})
	}
	id, err := strconv.Atoi(c.Params("id"))
	if err != nil {
		return c.SendStatus(404)
	}
	ctx := c.Context()
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
	body, _ := json.Marshal(items[0])
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
	id, err := strconv.Atoi(c.Params("id"))
	if err != nil {
		return c.SendStatus(404)
	}
	var b crudBody
	if err := json.Unmarshal(c.Body(), &b); err != nil {
		return c.Status(500).JSON(fiber.Map{"error": "update failed"})
	}
	if b.Name == "" {
		b.Name = "Updated"
	}
	ctx := c.Context()
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

// Static bodies are read from disk on every request, which the static profiles
// require in every mode. Standard mode leaves the encoding to the compress
// middleware mounted above rather than serving a pre-compressed sibling.
func staticFile(c fiber.Ctx) error {
	name := c.Params("filename")
	if name == "" || strings.Contains(name, "/") || strings.Contains(name, "..") {
		return c.SendStatus(404)
	}
	data, err := os.ReadFile("/data/static/" + name)
	if err != nil {
		return c.SendStatus(404)
	}
	ct := mimeTypes[filepath.Ext(name)]
	if ct == "" {
		ct = "application/octet-stream"
	}
	c.Set("Content-Type", ct)
	return c.Send(data)
}

func main() {
	loadDataset()
	loadPgPool()
	loadRedis()

	app := fiber.New(fiber.Config{
		BodyLimit: maxBody,
	})
	app.Use(compress.New())

	app.Get("/pipeline", pipeline)
	app.Get("/baseline11", baseline11)
	app.Post("/baseline11", baseline11)
	app.Get("/json/:count", jsonItems)
	app.Post("/upload", upload)
	app.Get("/baseline2", baseline11)
	app.Get("/static/:filename", staticFile)
	app.Get("/async-db", asyncDb)
	app.Get("/crud/items", crudList)
	app.Post("/crud/items", crudCreate)
	app.Get("/crud/items/:id", crudRead)
	app.Put("/crud/items/:id", crudUpdate)

	// json-tls and static-tls on 8081, the same app behind TLS. The harness only
	// mounts /certs for the TLS profiles, so without them it is not opened.
	const cert, key = "/certs/server.crt", "/certs/server.key"
	if _, err := os.Stat(cert); err == nil {
		if _, err := os.Stat(key); err == nil {
			go app.Listen(":8081", fiber.ListenConfig{
				DisableStartupMessage: true,
				CertFile:              cert,
				CertKeyFile:           key,
			})
		}
	}

	app.Listen(":8080", fiber.ListenConfig{DisableStartupMessage: true})
}
