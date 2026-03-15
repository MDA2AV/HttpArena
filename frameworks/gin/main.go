package main

import (
	"compress/flate"
	"compress/gzip"
	"database/sql"
	"encoding/json"
	"fmt"
	"math"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"github.com/gin-gonic/gin"
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
	loadStaticFiles()

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()

	r.GET("/pipeline", func(c *gin.Context) {
		c.Header("Server", "gin")
		c.String(http.StatusOK, "ok")
	})

	baseline11 := func(c *gin.Context) {
		sum := parseQuerySum(c.Request.URL.RawQuery)
		if c.Request.Method == "POST" {
			body, _ := c.GetRawData()
			if n, err := strconv.ParseInt(strings.TrimSpace(string(body)), 10, 64); err == nil {
				sum += n
			}
		}
		c.Header("Server", "gin")
		c.String(http.StatusOK, strconv.FormatInt(sum, 10))
	}
	r.GET("/baseline11", baseline11)
	r.POST("/baseline11", baseline11)

	baseline2 := func(c *gin.Context) {
		sum := parseQuerySum(c.Request.URL.RawQuery)
		c.Header("Server", "gin")
		c.String(http.StatusOK, strconv.FormatInt(sum, 10))
	}
	r.GET("/baseline2", baseline2)

	r.GET("/json", func(c *gin.Context) {
		items := make([]ProcessedItem, len(dataset))
		for i, d := range dataset {
			items[i] = ProcessedItem{
				ID: d.ID, Name: d.Name, Category: d.Category,
				Price: d.Price, Quantity: d.Quantity, Active: d.Active,
				Tags: d.Tags, Rating: d.Rating,
				Total: math.Round(d.Price*float64(d.Quantity)*100) / 100,
			}
		}
		c.Header("Server", "gin")
		c.Header("Content-Type", "application/json")
		data, _ := json.Marshal(ProcessResponse{Items: items, Count: len(items)})
		c.Data(http.StatusOK, "application/json", data)
	})

	r.GET("/compression", func(c *gin.Context) {
		c.Header("Server", "gin")
		ae := c.GetHeader("Accept-Encoding")
		if strings.Contains(ae, "deflate") {
			c.Header("Content-Type", "application/json")
			c.Header("Content-Encoding", "deflate")
			c.Status(http.StatusOK)
			w, err := flate.NewWriter(c.Writer, flate.BestSpeed)
			if err == nil {
				w.Write(jsonLargeResponse)
				w.Close()
			}
		} else if strings.Contains(ae, "gzip") {
			c.Header("Content-Type", "application/json")
			c.Header("Content-Encoding", "gzip")
			c.Status(http.StatusOK)
			w, err := gzip.NewWriterLevel(c.Writer, gzip.BestSpeed)
			if err == nil {
				w.Write(jsonLargeResponse)
				w.Close()
			}
		} else {
			c.Data(http.StatusOK, "application/json", jsonLargeResponse)
		}
	})

	r.POST("/upload", func(c *gin.Context) {
		body, _ := c.GetRawData()
		c.Header("Server", "gin")
		c.String(http.StatusOK, fmt.Sprintf("%d", len(body)))
	})

	r.GET("/db", func(c *gin.Context) {
		if db == nil {
			c.String(http.StatusInternalServerError, "DB not available")
			return
		}
		minPrice := 10.0
		maxPrice := 50.0
		if v := c.Query("min"); v != "" {
			if f, err := strconv.ParseFloat(v, 64); err == nil {
				minPrice = f
			}
		}
		if v := c.Query("max"); v != "" {
			if f, err := strconv.ParseFloat(v, 64); err == nil {
				maxPrice = f
			}
		}
		rows, err := db.Query("SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50", minPrice, maxPrice)
		if err != nil {
			c.String(http.StatusInternalServerError, "Query failed")
			return
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
		c.Header("Server", "gin")
		c.Header("Content-Type", "application/json")
		data, _ := json.Marshal(gin.H{"items": items, "count": len(items)})
		c.Data(http.StatusOK, "application/json", data)
	})

	r.GET("/static/:filename", func(c *gin.Context) {
		filename := c.Param("filename")
		if sf, ok := staticFiles[filename]; ok {
			c.Header("Server", "gin")
			c.Data(http.StatusOK, sf.ContentType, sf.Data)
		} else {
			c.Status(http.StatusNotFound)
		}
	})

	r.Run(":8080")
}
