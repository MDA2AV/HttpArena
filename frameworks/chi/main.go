package main

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"

	"github.com/go-chi/chi/v5"
	"github.com/go-chi/chi/v5/middleware"
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

func main() {
	loadDataset()

	r := chi.NewRouter()
	// standard mode: gzip is chi's own middleware.Compress, no hand-rolled encoder
	r.Use(middleware.Compress(5))

	r.Get("/pipeline", pipeline)
	r.Get("/baseline11", baseline11)
	r.Post("/baseline11", baseline11)
	r.Get("/json/{count}", jsonItems)
	r.Post("/upload", upload)

	http.ListenAndServe(":8080", r)
}
