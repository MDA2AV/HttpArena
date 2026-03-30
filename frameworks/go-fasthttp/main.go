package main

import (
	"context"
	"database/sql"
	"encoding/json"
	"log"
	"math"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"

	"compress/flate"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/valyala/fasthttp"
	"github.com/valyala/fasthttp/reuseport"
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
	var raw []struct {
		ID       int      `json:"id"`
		Name     string   `json:"name"`
		Category string   `json:"category"`
		Price    float64  `json:"price"`
		Quantity int      `json:"quantity"`
		Active   bool     `json:"active"`
		Tags     []string `json:"tags"`
		Rating   Rating   `json:"rating"`
	}
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

func processHandler(ctx *fasthttp.RequestCtx) {
	items := make([]ProcessedItem, len(dataset))
	for i, d := range dataset {
		items[i] = ProcessedItem{
			ID:       d.ID,
			Name:     d.Name,
			Category: d.Category,
			Price:    d.Price,
			Quantity: d.Quantity,
			Active:   d.Active,
			Tags:     d.Tags,
			Rating:   d.Rating,
			Total:    math.Round(d.Price*float64(d.Quantity)*100) / 100,
		}
	}

	resp := ProcessResponse{Items: items, Count: len(items)}
	ctx.Response.Header.Set("Server", "go-fasthttp")
	ctx.SetContentType("application/json")
	body, _ := json.Marshal(resp)
	ctx.SetBody(body)
}

func loadDB() {
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
	rows, err := pgPool.Query(context.Background(), "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN $1 AND $2 LIMIT 50", minPrice, maxPrice)
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
	resp := map[string]interface{}{"items": items, "count": len(items)}
	ctx.Response.Header.Set("Server", "go-fasthttp")
	ctx.SetContentType("application/json")
	body, _ := json.Marshal(resp)
	ctx.SetBody(body)
}

var compressedHandler fasthttp.RequestHandler

func main() {
	loadDataset()
	loadDatasetLarge()
	loadDB()
	loadPgPool()

	compressedHandler = fasthttp.CompressHandlerLevel(func(ctx *fasthttp.RequestCtx) {
		ctx.Response.Header.Set("Server", "go-fasthttp")
		ctx.SetContentType("application/json")
		ctx.SetBody(jsonLargeResponse)
	}, flate.BestSpeed)

	fsHandler := (&fasthttp.FS{
        Root:            "/data/static",
        Compress:        true,
        AcceptByteRange: true,
    }).NewRequestHandler()

	staticHandler := func(ctx *fasthttp.RequestCtx) {
		ctx.URI().SetPathBytes(ctx.Path()[len("/static"):])
		fsHandler(ctx)
	}

	handler := func(ctx *fasthttp.RequestCtx) {
		switch string(ctx.Path()) {
		case "/pipeline":
			pipelineHandler(ctx)
		case "/json":
			processHandler(ctx)
		case "/compression":
			compressedHandler(ctx)
		case "/upload":
			uploadHandler(ctx)
		case "/db":
			dbHandler(ctx)
		case "/async-db":
			asyncDbHandler(ctx)
		default:
            if strings.HasPrefix(string(ctx.Path()), "/static/") {
                staticHandler(ctx)
                return
            }
			if strings.HasPrefix(string(ctx.Path()), "/baseline") {
				baseline11Handler(ctx)
				return
			}

			ctx.SetStatusCode(fasthttp.StatusNotFound)
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
	}
	wg.Wait()
}
