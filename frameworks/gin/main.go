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

	"github.com/gin-contrib/gzip"
	"github.com/gin-gonic/gin"
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

func pipeline(c *gin.Context) {
	c.String(http.StatusOK, "ok")
}

func baseline11(c *gin.Context) {
	sum := 0
	for _, values := range c.Request.URL.Query() {
		for _, v := range values {
			if n, err := strconv.Atoi(v); err == nil {
				sum += n
			}
		}
	}
	if c.Request.Method == http.MethodPost {
		body, err := io.ReadAll(c.Request.Body)
		if err == nil {
			if n, err := strconv.Atoi(strings.TrimSpace(string(body))); err == nil {
				sum += n
			}
		}
	}
	c.String(http.StatusOK, strconv.Itoa(sum))
}

func jsonItems(c *gin.Context) {
	count, _ := strconv.Atoi(c.Param("count"))
	if count < 0 {
		count = 0
	}
	if count > len(dataset) {
		count = len(dataset)
	}
	m, err := strconv.Atoi(c.DefaultQuery("m", "1"))
	if err != nil || m == 0 {
		m = 1
	}

	items := make([]ProcessedItem, count)
	for i := 0; i < count; i++ {
		d := dataset[i]
		items[i] = ProcessedItem{DatasetItem: d, Total: d.Price * d.Quantity * m}
	}
	c.JSON(http.StatusOK, ProcessResponse{Items: items, Count: count})
}

func upload(c *gin.Context) {
	size, err := io.Copy(io.Discard, c.Request.Body)
	if err != nil {
		c.String(http.StatusBadRequest, "0")
		return
	}
	c.String(http.StatusOK, strconv.FormatInt(size, 10))
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
func scanItem(rows interface {
	Scan(dest ...any) error
}) (DatasetItem, error) {
	var it DatasetItem
	var tags []byte
	err := rows.Scan(&it.ID, &it.Name, &it.Category, &it.Price, &it.Quantity,
		&it.Active, &tags, &it.Rating.Score, &it.Rating.Count)
	if err != nil {
		return it, err
	}
	json.Unmarshal(tags, &it.Tags)
	if it.Tags == nil {
		it.Tags = []string{}
	}
	return it, nil
}

func queryItems(ctx context.Context, sql string, args ...any) ([]DatasetItem, error) {
	rows, err := pgPool.Query(ctx, sql, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	items := []DatasetItem{}
	for rows.Next() {
		it, err := scanItem(rows)
		if err != nil {
			continue
		}
		items = append(items, it)
	}
	return items, nil
}

func asyncDb(c *gin.Context) {
	if pgPool == nil {
		c.JSON(http.StatusOK, gin.H{"items": []DatasetItem{}, "count": 0})
		return
	}
	minPrice := queryInt(c, "min", 10)
	maxPrice := queryInt(c, "max", 50)
	limit := clamp(queryInt(c, "limit", 50), 1, 50)
	items, err := queryItems(c.Request.Context(),
		"SELECT "+itemColumns+" FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
		minPrice, maxPrice, limit)
	if err != nil {
		c.JSON(http.StatusOK, gin.H{"items": []DatasetItem{}, "count": 0})
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": items, "count": len(items)})
}

func crudList(c *gin.Context) {
	if pgPool == nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "DB not available"})
		return
	}
	category := c.DefaultQuery("category", "electronics")
	page := queryInt(c, "page", 1)
	if page < 1 {
		page = 1
	}
	limit := clamp(queryInt(c, "limit", 10), 1, 50)
	items, err := queryItems(c.Request.Context(),
		"SELECT "+itemColumns+" FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3",
		category, limit, (page-1)*limit)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "query failed"})
		return
	}
	c.JSON(http.StatusOK, gin.H{"items": items, "total": len(items), "page": page, "limit": limit})
}

type crudBody struct {
	ID       int    `json:"id"`
	Name     string `json:"name"`
	Category string `json:"category"`
	Price    int    `json:"price"`
	Quantity int    `json:"quantity"`
}

func crudCreate(c *gin.Context) {
	if pgPool == nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "DB not available"})
		return
	}
	var b crudBody
	if err := c.ShouldBindJSON(&b); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "insert failed"})
		return
	}
	if b.Name == "" {
		b.Name = "New Product"
	}
	if b.Category == "" {
		b.Category = "test"
	}
	var id int
	err := pgPool.QueryRow(c.Request.Context(),
		`INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count)
		 VALUES ($1, $2, $3, $4, $5, true, '["bench"]', 0, 0)
		 ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5 RETURNING id`,
		b.ID, b.Name, b.Category, b.Price, b.Quantity).Scan(&id)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "insert failed"})
		return
	}
	c.JSON(http.StatusCreated, gin.H{"id": id, "name": b.Name, "category": b.Category,
		"price": b.Price, "quantity": b.Quantity})
}

// Cache-aside on Redis where the harness provides it - crud is the one profile
// that does.
func crudRead(c *gin.Context) {
	if pgPool == nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "DB not available"})
		return
	}
	id, err := strconv.Atoi(c.Param("id"))
	if err != nil {
		c.Status(http.StatusNotFound)
		return
	}
	ctx := c.Request.Context()
	key := "crud:" + strconv.Itoa(id)
	if rdb != nil {
		if hit, err := rdb.Get(ctx, key).Result(); err == nil && hit != "" {
			c.Header("X-Cache", "HIT")
			c.Data(http.StatusOK, "application/json", []byte(hit))
			return
		}
	}
	items, err := queryItems(ctx, "SELECT "+itemColumns+" FROM items WHERE id = $1 LIMIT 1", id)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "query failed"})
		return
	}
	if len(items) == 0 {
		c.Status(http.StatusNotFound)
		return
	}
	body, _ := json.Marshal(items[0])
	if rdb != nil {
		rdb.Set(ctx, key, body, crudTTL)
	}
	c.Header("X-Cache", "MISS")
	c.Data(http.StatusOK, "application/json", body)
}

func crudUpdate(c *gin.Context) {
	if pgPool == nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "DB not available"})
		return
	}
	id, err := strconv.Atoi(c.Param("id"))
	if err != nil {
		c.Status(http.StatusNotFound)
		return
	}
	var b crudBody
	if err := c.ShouldBindJSON(&b); err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "update failed"})
		return
	}
	if b.Name == "" {
		b.Name = "Updated"
	}
	ctx := c.Request.Context()
	tag, err := pgPool.Exec(ctx,
		"UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4",
		b.Name, b.Price, b.Quantity, id)
	if err != nil {
		c.JSON(http.StatusInternalServerError, gin.H{"error": "update failed"})
		return
	}
	if tag.RowsAffected() == 0 {
		c.Status(http.StatusNotFound)
		return
	}
	if rdb != nil {
		rdb.Del(ctx, "crud:"+strconv.Itoa(id))
	}
	c.JSON(http.StatusOK, gin.H{"id": id, "name": b.Name, "price": b.Price, "quantity": b.Quantity})
}

var mimeTypes = map[string]string{
	".css": "text/css", ".js": "application/javascript", ".html": "text/html",
	".woff2": "font/woff2", ".svg": "image/svg+xml", ".webp": "image/webp",
	".json": "application/json",
}

// Static bodies are read from disk on every request, which the static profiles
// require in every mode. Standard mode leaves the encoding to the gzip
// middleware mounted above rather than serving a pre-compressed sibling.
func staticFile(c *gin.Context) {
	name := c.Param("filename")
	if name == "" || strings.Contains(name, "/") || strings.Contains(name, "..") {
		c.Status(http.StatusNotFound)
		return
	}
	data, err := os.ReadFile("/data/static/" + name)
	if err != nil {
		c.Status(http.StatusNotFound)
		return
	}
	ct := mimeTypes[filepath.Ext(name)]
	if ct == "" {
		ct = "application/octet-stream"
	}
	c.Data(http.StatusOK, ct, data)
}

func queryInt(c *gin.Context, name string, fallback int) int {
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

func main() {
	loadDataset()
	loadPgPool()
	loadRedis()

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Recovery())
	r.Use(gzip.Gzip(gzip.DefaultCompression))

	r.GET("/pipeline", pipeline)
	r.GET("/baseline11", baseline11)
	r.POST("/baseline11", baseline11)
	r.GET("/json/:count", jsonItems)
	r.POST("/upload", upload)
	r.GET("/baseline2", baseline11)
	r.GET("/static/:filename", staticFile)
	r.GET("/async-db", asyncDb)
	r.GET("/crud/items", crudList)
	r.POST("/crud/items", crudCreate)
	r.GET("/crud/items/:id", crudRead)
	r.PUT("/crud/items/:id", crudUpdate)

	// json-tls and static-tls on 8081, the same router behind TLS. The harness
	// only mounts /certs for the TLS profiles, so without them it is not opened.
	const cert, key = "/certs/server.crt", "/certs/server.key"
	if _, err := os.Stat(cert); err == nil {
		if _, err := os.Stat(key); err == nil {
			go r.RunTLS(":8081", cert, key)
		}
	}

	r.Run(":8080")
}
