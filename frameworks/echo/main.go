package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"io"
	"math"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/labstack/echo/v4"
	"github.com/labstack/echo/v4/middleware"
	_ "modernc.org/sqlite"
)

type Rating struct {
	Score float64 `json:"score"`
	Count int     `json:"count"`
}

type DatasetItem struct {
	ID       int      `json:"id"`
	Name     string   `json:"name"`
	Category string   `json:"category"`
	Price    float64  `json:"price"`
	Quantity int      `json:"quantity"`
	Active   bool     `json:"active"`
	Tags     []string `json:"tags"`
	Rating   Rating   `json:"rating"`
}

type ProcessedItem struct {
	ID       int      `json:"id"`
	Name     string   `json:"name"`
	Category string   `json:"category"`
	Price    float64  `json:"price"`
	Quantity int      `json:"quantity"`
	Active   bool     `json:"active"`
	Tags     []string `json:"tags"`
	Rating   Rating   `json:"rating"`
	Total    float64  `json:"total"`
}

type ProcessResponse struct {
	Items []ProcessedItem `json:"items"`
	Count int             `json:"count"`
}

var dataset []DatasetItem
var jsonLargeResponse []byte
var db *sql.DB
var pgPool *pgxpool.Pool

type StaticFile struct {
	Data        []byte
	ContentType string
}

var staticFiles map[string]StaticFile

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

func loadDatasetLarge() {
	data, err := os.ReadFile("/data/dataset-large.json")
	if err != nil {
		return
	}
	var raw []DatasetItem
	if json.Unmarshal(data, &raw) != nil {
		return
	}
	items := make([]ProcessedItem, len(raw))
	for i, d := range raw {
		items[i] = ProcessedItem{
			ID: d.ID, Name: d.Name, Category: d.Category,
			Price: d.Price, Quantity: d.Quantity, Active: d.Active,
			Tags: d.Tags, Rating: d.Rating,
			Total: math.Round(d.Price*float64(d.Quantity)*100) / 100,
		}
	}
	jsonLargeResponse, _ = json.Marshal(ProcessResponse{Items: items, Count: len(items)})
}

func loadDB() {
	d, err := sql.Open("sqlite", "file:/data/benchmark.db?mode=ro&immutable=1")
	if err != nil {
		return
	}
	d.SetMaxOpenConns(runtime.NumCPU())
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

func loadStaticFiles() {
	staticFiles = make(map[string]StaticFile)
	entries, err := os.ReadDir("/data/static")
	if err != nil {
		return
	}
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		data, err := os.ReadFile(filepath.Join("/data/static", name))
		if err != nil {
			continue
		}
		ct := mime.TypeByExtension(filepath.Ext(name))
		if ct == "" {
			ct = "application/octet-stream"
		}
		staticFiles[name] = StaticFile{Data: data, ContentType: ct}
	}
}

func parseQuerySum(query string) int64 {
	var sum int64
	for _, pair := range strings.Split(query, "&") {
		parts := strings.SplitN(pair, "=", 2)
		if len(parts) == 2 {
			if n, err := strconv.ParseInt(parts[1], 10, 64); err == nil {
				sum += n
			}
		}
	}
	return sum
}

func main() {
	loadDataset()
	loadDatasetLarge()
	loadDB()
	loadPgPool()
	loadStaticFiles()

	e := echo.New()
	e.HideBanner = true
	e.HidePort = true

	e.Use(middleware.GzipWithConfig(middleware.GzipConfig{
		Level: 1,
	}))

	e.GET("/pipeline", func(c echo.Context) error {
		c.Response().Header().Set("Server", "echo")
		return c.String(http.StatusOK, "ok")
	})

	baseline11 := func(c echo.Context) error {
		sum := parseQuerySum(c.Request().URL.RawQuery)
		if c.Request().Method == "POST" {
			body, _ := io.ReadAll(c.Request().Body)
			if n, err := strconv.ParseInt(strings.TrimSpace(string(body)), 10, 64); err == nil {
				sum += n
			}
		}
		c.Response().Header().Set("Server", "echo")
		return c.String(http.StatusOK, strconv.FormatInt(sum, 10))
	}
	e.GET("/baseline11", baseline11)
	e.POST("/baseline11", baseline11)

	e.GET("/baseline2", func(c echo.Context) error {
		sum := parseQuerySum(c.Request().URL.RawQuery)
		c.Response().Header().Set("Server", "echo")
		return c.String(http.StatusOK, strconv.FormatInt(sum, 10))
	})

	e.GET("/json", func(c echo.Context) error {
		items := make([]ProcessedItem, len(dataset))
		for i, d := range dataset {
			items[i] = ProcessedItem{
				ID: d.ID, Name: d.Name, Category: d.Category,
				Price: d.Price, Quantity: d.Quantity, Active: d.Active,
				Tags: d.Tags, Rating: d.Rating,
				Total: math.Round(d.Price*float64(d.Quantity)*100) / 100,
			}
		}
		c.Response().Header().Set("Server", "echo")
		data, _ := json.Marshal(ProcessResponse{Items: items, Count: len(items)})
		return c.Blob(http.StatusOK, "application/json", data)
	})

	e.GET("/compression", func(c echo.Context) error {
		c.Response().Header().Set("Server", "echo")
		return c.Blob(http.StatusOK, "application/json", jsonLargeResponse)
	})

	e.POST("/upload", func(c echo.Context) error {
		size, _ := io.Copy(io.Discard, c.Request().Body)
		c.Response().Header().Set("Server", "echo")
		return c.String(http.StatusOK, strconv.FormatInt(size, 10))
	})

	e.GET("/db", func(c echo.Context) error {
		if db == nil {
			return c.String(http.StatusInternalServerError, "DB not available")
		}
		minPrice := 10.0
		maxPrice := 50.0
		if v := c.QueryParam("min"); v != "" {
			if f, err := strconv.ParseFloat(v, 64); err == nil {
				minPrice = f
			}
		}
		if v := c.QueryParam("max"); v != "" {
			if f, err := strconv.ParseFloat(v, 64); err == nil {
				maxPrice = f
			}
		}
		rows, err := db.Query("SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50", minPrice, maxPrice)
		if err != nil {
			return c.String(http.StatusInternalServerError, "Query failed")
		}
		defer rows.Close()
		var items []map[string]interface{}
		for rows.Next() {
			var id, quantity, active, ratingCount int
			var name, category, tags string
			var price, ratingScore float64
			if err := rows.Scan(&id, &name, &category, &price, &quantity, &active, &tags, &ratingScore, &ratingCount); err != nil {
				continue
			}
			var tagsArr []string
			json.Unmarshal([]byte(tags), &tagsArr)
			items = append(items, map[string]interface{}{
				"id": id, "name": name, "category": category,
				"price": price, "quantity": quantity, "active": active == 1,
				"tags": tagsArr,
				"rating": map[string]interface{}{"score": ratingScore, "count": ratingCount},
			})
		}
		c.Response().Header().Set("Server", "echo")
		data, _ := json.Marshal(map[string]interface{}{"items": items, "count": len(items)})
		return c.Blob(http.StatusOK, "application/json", data)
	})

	e.GET("/async-db", func(c echo.Context) error {
		if pgPool == nil {
			c.Response().Header().Set("Server", "echo")
			return c.Blob(http.StatusOK, "application/json", []byte(`{"items":[],"count":0}`))
		}
		minPrice := 10.0
		maxPrice := 50.0
		if v := c.QueryParam("min"); v != "" {
			if f, err := strconv.ParseFloat(v, 64); err == nil {
				minPrice = f
			}
		}
		if v := c.QueryParam("max"); v != "" {
			if f, err := strconv.ParseFloat(v, 64); err == nil {
				maxPrice = f
			}
		}
		rows, err := pgPool.Query(c.Request().Context(), "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT 50", minPrice, maxPrice)
		if err != nil {
			c.Response().Header().Set("Server", "echo")
			return c.Blob(http.StatusOK, "application/json", []byte(`{"items":[],"count":0}`))
		}
		defer rows.Close()
		var items []map[string]interface{}
		for rows.Next() {
			var id, quantity, ratingCount int
			var name, category string
			var price, ratingScore float64
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
				"tags": tagsArr,
				"rating": map[string]interface{}{"score": ratingScore, "count": ratingCount},
			})
		}
		if items == nil {
			items = []map[string]interface{}{}
		}
		c.Response().Header().Set("Server", "echo")
		data, _ := json.Marshal(map[string]interface{}{"items": items, "count": len(items)})
		return c.Blob(http.StatusOK, "application/json", data)
	})

	e.GET("/static/:filename", func(c echo.Context) error {
		filename := c.Param("filename")
		if sf, ok := staticFiles[filename]; ok {
			c.Response().Header().Set("Server", "echo")
			return c.Blob(http.StatusOK, sf.ContentType, sf.Data)
		}
		return c.NoContent(http.StatusNotFound)
	})

	e.Start(":8080")
}
