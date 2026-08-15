package main

import (
	"encoding/json"
	"os"
	"strconv"
	"strings"

	"github.com/gofiber/fiber/v3"
	"github.com/gofiber/fiber/v3/middleware/compress"
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

func main() {
	loadDataset()

	app := fiber.New(fiber.Config{
		BodyLimit: maxBody,
	})
	app.Use(compress.New())

	app.Get("/pipeline", pipeline)
	app.Get("/baseline11", baseline11)
	app.Post("/baseline11", baseline11)
	app.Get("/json/:count", jsonItems)
	app.Post("/upload", upload)

	app.Listen(":8080", fiber.ListenConfig{DisableStartupMessage: true})
}
