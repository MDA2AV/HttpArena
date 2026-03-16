package main

import (
	"compress/flate"
	"compress/gzip"
	"database/sql"
	"encoding/json"
	"fmt"
	"math"
	"mime"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"

	"github.com/gofiber/fiber/v2"
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

	app := fiber.New(fiber.Config{
		DisableStartupMessage: true,
		BodyLimit:             25 * 1024 * 1024, // 25 MB
		Prefork:               true,
	})

	app.Get("/pipeline", func(c *fiber.Ctx) error {
		c.Set("Server", "fiber")
		return c.SendString("ok")
	})

	baseline11 := func(c *fiber.Ctx) error {
		sum := parseQuerySum(c.Context().URI().QueryArgs().String())
		if c.Method() == "POST" {
			body := c.Body()
			if n, err := strconv.ParseInt(strings.TrimSpace(string(body)), 10, 64); err == nil {
				sum += n
			}
		}
		c.Set("Server", "fiber")
		return c.SendString(strconv.FormatInt(sum, 10))
	}
	app.Get("/baseline11", baseline11)
	app.Post("/baseline11", baseline11)

	app.Get("/baseline2", func(c *fiber.Ctx) error {
		sum := parseQuerySum(c.Context().URI().QueryArgs().String())
		c.Set("Server", "fiber")
		return c.SendString(strconv.FormatInt(sum, 10))
	})

	app.Get("/json", func(c *fiber.Ctx) error {
		items := make([]ProcessedItem, len(dataset))
		for i, d := range dataset {
			items[i] = ProcessedItem{
				ID: d.ID, Name: d.Name, Category: d.Category,
				Price: d.Price, Quantity: d.Quantity, Active: d.Active,
				Tags: d.Tags, Rating: d.Rating,
				Total: math.Round(d.Price*float64(d.Quantity)*100) / 100,
			}
		}
		c.Set("Server", "fiber")
		c.Set("Content-Type", "application/json")
		data, _ := json.Marshal(ProcessResponse{Items: items, Count: len(items)})
		return c.Send(data)
	})

	app.Get("/compression", func(c *fiber.Ctx) error {
		c.Set("Server", "fiber")
		ae := c.Get("Accept-Encoding")
		if strings.Contains(ae, "deflate") {
			c.Set("Content-Type", "application/json")
			c.Set("Content-Encoding", "deflate")
			w, err := flate.NewWriter(c.Response().BodyWriter(), flate.BestSpeed)
			if err == nil {
				w.Write(jsonLargeResponse)
				w.Close()
			}
			return nil
		} else if strings.Contains(ae, "gzip") {
			c.Set("Content-Type", "application/json")
			c.Set("Content-Encoding", "gzip")
			w, err := gzip.NewWriterLevel(c.Response().BodyWriter(), gzip.BestSpeed)
			if err == nil {
				w.Write(jsonLargeResponse)
				w.Close()
			}
			return nil
		}
		c.Set("Content-Type", "application/json")
		return c.Send(jsonLargeResponse)
	})

	app.Post("/upload", func(c *fiber.Ctx) error {
		body := c.Body()
		c.Set("Server", "fiber")
		return c.SendString(fmt.Sprintf("%d", len(body)))
	})

	app.Get("/db", func(c *fiber.Ctx) error {
		if db == nil {
			return c.Status(500).SendString("DB not available")
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
			return c.Status(500).SendString("Query failed")
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
		c.Set("Server", "fiber")
		c.Set("Content-Type", "application/json")
		data, _ := json.Marshal(map[string]interface{}{"items": items, "count": len(items)})
		return c.Send(data)
	})

	app.Get("/static/:filename", func(c *fiber.Ctx) error {
		filename := c.Params("filename")
		if sf, ok := staticFiles[filename]; ok {
			c.Set("Server", "fiber")
			c.Set("Content-Type", sf.ContentType)
			return c.Send(sf.Data)
		}
		return c.SendStatus(404)
	})

	app.Listen(":8080")
}
