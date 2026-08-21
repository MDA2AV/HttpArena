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

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
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

// A missing or unreadable dataset leaves the slice empty, so /json still answers
// with an empty list instead of taking the process down.
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

func pipeline(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	w.Write([]byte("ok"))
}

func baseline11(w http.ResponseWriter, r *http.Request) {
	sum := 0
	for _, values := range r.URL.Query() {
		for _, v := range values {
			if n, err := strconv.Atoi(v); err == nil {
				sum += n
			}
		}
	}
	if r.Method == http.MethodPost {
		body, err := io.ReadAll(r.Body)
		if err == nil {
			if n, err := strconv.Atoi(strings.TrimSpace(string(body))); err == nil {
				sum += n
			}
		}
	}
	w.Header().Set("Content-Type", "text/plain")
	w.Write([]byte(strconv.Itoa(sum)))
}

func jsonItems(w http.ResponseWriter, r *http.Request) {
	count, _ := strconv.Atoi(chi.URLParam(r, "count"))
	if count < 0 {
		count = 0
	}
	if count > len(dataset) {
		count = len(dataset)
	}
	m, err := strconv.Atoi(r.URL.Query().Get("m"))
	if err != nil || m == 0 {
		m = 1
	}

	items := make([]ProcessedItem, count)
	for i := 0; i < count; i++ {
		d := dataset[i]
		items[i] = ProcessedItem{DatasetItem: d, Total: d.Price * d.Quantity * m}
	}
	// Content-Type has to be set before the first write: the Compress middleware
	// reads it to decide whether the body is compressible.
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(ProcessResponse{Items: items, Count: count})
}

func upload(w http.ResponseWriter, r *http.Request) {
	size, err := io.Copy(io.Discard, r.Body)
	w.Header().Set("Content-Type", "text/plain")
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		w.Write([]byte("0"))
		return
	}
	w.Write([]byte(strconv.FormatInt(size, 10)))
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

func queryInt(r *http.Request, name string, fallback int) int {
	if v := r.URL.Query().Get(name); v != "" {
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

func writeJSON(w http.ResponseWriter, status int, v any) {
	body, _ := json.Marshal(v)
	w.Header().Set("Content-Type", "application/json")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(status)
	w.Write(body)
}

const emptyItems = `{"items":[],"count":0}`

func writeRaw(w http.ResponseWriter, status int, body []byte, extraKey, extraVal string) {
	h := w.Header()
	h.Set("Content-Type", "application/json")
	if extraKey != "" {
		h.Set(extraKey, extraVal)
	}
	h.Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(status)
	w.Write(body)
}

func asyncDb(w http.ResponseWriter, r *http.Request) {
	if pgPool == nil {
		writeRaw(w, http.StatusOK, []byte(emptyItems), "", "")
		return
	}
	items, err := queryItems(r.Context(),
		"SELECT "+itemColumns+" FROM items WHERE price BETWEEN $1 AND $2 LIMIT $3",
		queryInt(r, "min", 10), queryInt(r, "max", 50), clamp(queryInt(r, "limit", 50), 1, 50))
	if err != nil {
		writeRaw(w, http.StatusOK, []byte(emptyItems), "", "")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"items": items, "count": len(items)})
}

func crudList(w http.ResponseWriter, r *http.Request) {
	if pgPool == nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "DB not available"})
		return
	}
	category := r.URL.Query().Get("category")
	if category == "" {
		category = "electronics"
	}
	page := queryInt(r, "page", 1)
	if page < 1 {
		page = 1
	}
	limit := clamp(queryInt(r, "limit", 10), 1, 50)
	items, err := queryItems(r.Context(),
		"SELECT "+itemColumns+" FROM items WHERE category = $1 ORDER BY id LIMIT $2 OFFSET $3",
		category, limit, (page-1)*limit)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "query failed"})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"items": items, "total": len(items), "page": page, "limit": limit})
}

type crudBody struct {
	ID       int    `json:"id"`
	Name     string `json:"name"`
	Category string `json:"category"`
	Price    int    `json:"price"`
	Quantity int    `json:"quantity"`
}

func readCrudBody(r *http.Request) (crudBody, error) {
	var b crudBody
	data, err := io.ReadAll(r.Body)
	if err != nil {
		return b, err
	}
	err = json.Unmarshal(data, &b)
	return b, err
}

func crudCreate(w http.ResponseWriter, r *http.Request) {
	if pgPool == nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "DB not available"})
		return
	}
	b, err := readCrudBody(r)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "insert failed"})
		return
	}
	if b.Name == "" {
		b.Name = "New Product"
	}
	if b.Category == "" {
		b.Category = "test"
	}
	var id int
	err = pgPool.QueryRow(r.Context(),
		`INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count)
		 VALUES ($1, $2, $3, $4, $5, true, '["bench"]', 0, 0)
		 ON CONFLICT (id) DO UPDATE SET name = $2, price = $4, quantity = $5 RETURNING id`,
		b.ID, b.Name, b.Category, b.Price, b.Quantity).Scan(&id)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "insert failed"})
		return
	}
	writeJSON(w, http.StatusCreated, map[string]any{"id": id, "name": b.Name,
		"category": b.Category, "price": b.Price, "quantity": b.Quantity})
}

// Cache-aside on Redis where the harness provides it - crud is the one profile
// that does.
func crudRead(w http.ResponseWriter, r *http.Request) {
	if pgPool == nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "DB not available"})
		return
	}
	id, err := strconv.Atoi(chi.URLParam(r, "id"))
	if err != nil {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	ctx := r.Context()
	key := "crud:" + strconv.Itoa(id)
	if rdb != nil {
		if hit, err := rdb.Get(ctx, key).Result(); err == nil && hit != "" {
			writeRaw(w, http.StatusOK, []byte(hit), "X-Cache", "HIT")
			return
		}
	}
	items, err := queryItems(ctx, "SELECT "+itemColumns+" FROM items WHERE id = $1 LIMIT 1", id)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "query failed"})
		return
	}
	if len(items) == 0 {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	body, _ := json.Marshal(items[0])
	if rdb != nil {
		rdb.Set(ctx, key, body, crudTTL)
	}
	writeRaw(w, http.StatusOK, body, "X-Cache", "MISS")
}

func crudUpdate(w http.ResponseWriter, r *http.Request) {
	if pgPool == nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "DB not available"})
		return
	}
	id, err := strconv.Atoi(chi.URLParam(r, "id"))
	if err != nil {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	b, err := readCrudBody(r)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "update failed"})
		return
	}
	if b.Name == "" {
		b.Name = "Updated"
	}
	ctx := r.Context()
	tag, err := pgPool.Exec(ctx,
		"UPDATE items SET name = $1, price = $2, quantity = $3 WHERE id = $4",
		b.Name, b.Price, b.Quantity, id)
	if err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": "update failed"})
		return
	}
	if tag.RowsAffected() == 0 {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	if rdb != nil {
		rdb.Del(ctx, "crud:"+strconv.Itoa(id))
	}
	writeJSON(w, http.StatusOK, map[string]any{"id": id, "name": b.Name,
		"price": b.Price, "quantity": b.Quantity})
}

var mimeTypes = map[string]string{
	".css": "text/css", ".js": "application/javascript", ".html": "text/html",
	".woff2": "font/woff2", ".svg": "image/svg+xml", ".webp": "image/webp",
	".json": "application/json",
}

// Static bodies are read from disk on every request, which the static profiles
// require in every mode. Standard mode leaves the encoding to the Compress middleware mounted
// above rather than serving a pre-compressed sibling.
func staticFile(w http.ResponseWriter, r *http.Request) {
	name := chi.URLParam(r, "filename")
	if name == "" || strings.Contains(name, "/") || strings.Contains(name, "..") {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	data, err := os.ReadFile("/data/static/" + name)
	if err != nil {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	ct := mimeTypes[filepath.Ext(name)]
	if ct == "" {
		ct = "application/octet-stream"
	}
	w.Header().Set("Content-Type", ct)
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.Write(data)
}

func main() {
	loadDataset()
	loadPgPool()
	loadRedis()

	r := chi.NewRouter()
	// standard mode: gzip is chi's own middleware.Compress, no hand-rolled encoder
	r.Use(middleware.Compress(5))

	r.Get("/pipeline", pipeline)
	r.Get("/baseline11", baseline11)
	r.Post("/baseline11", baseline11)
	r.Get("/json/{count}", jsonItems)
	r.Post("/upload", upload)
	r.Get("/baseline2", baseline11)
	r.Get("/static/{filename}", staticFile)
	r.Get("/async-db", asyncDb)
	r.Get("/crud/items", crudList)
	r.Post("/crud/items", crudCreate)
	r.Get("/crud/items/{id}", crudRead)
	r.Put("/crud/items/{id}", crudUpdate)

	// json-tls and static-tls on 8081, the same router behind TLS. The harness
	// only mounts /certs for the TLS profiles, so without them it is not opened.
	const cert, key = "/certs/server.crt", "/certs/server.key"
	if _, err := os.Stat(cert); err == nil {
		if _, err := os.Stat(key); err == nil {
			go http.ListenAndServeTLS(":8081", cert, key, r)
		}
	}

	http.ListenAndServe(":8080", r)
}
