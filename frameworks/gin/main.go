package main

import (
	"encoding/json"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"

	"github.com/gin-contrib/gzip"
	"github.com/gin-gonic/gin"
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

func main() {
	loadDataset()

	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Recovery())
	r.Use(gzip.Gzip(gzip.DefaultCompression))

	r.GET("/pipeline", pipeline)
	r.GET("/baseline11", baseline11)
	r.POST("/baseline11", baseline11)
	r.GET("/json/:count", jsonItems)
	r.POST("/upload", upload)

	r.Run(":8080")
}
