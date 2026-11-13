// Package httparena is the fit module that answers HttpArena's dynamic
// endpoints. It registers two handlers, compiled into fit as fit's own
// modules are (see main.go): httparena, the query sum of /baseline11 and
// /baseline2, and httparena_json, /json/{count}, whose body is serialized per
// request from the dataset read when the config is loaded.
//
// Both answer before ServeHTTP returns and never block: no disk or network
// I/O on a request, only what Provision built.
package httparena

import (
	"encoding/json"
	stdhttp "net/http"
	"os"
	"strconv"
	"strings"

	fibhttp "github.com/lesismal/fib/http"

	"github.com/lesismal/fit/module"
)

func init() {
	module.Register(module.Info{
		ID:  module.Handlers + ".httparena",
		New: func() any { return new(Baseline) },
		Doc: "Answers a + b from the query, plus the integer in the body on POST.",
	})
	module.Register(module.Info{
		ID:  module.Handlers + ".httparena_json",
		New: func() any { return new(JSON) },
		Doc: "Answers /json/{count}?m=M with the dataset's first count items, serialized per request.",
	})
}

const textPlain = "text/plain"

// Baseline answers a + b from the query, plus the integer in the body on POST.
type Baseline struct{}

func (*Baseline) Inline() {}

// ServeHTTP reads the parameters through Context.Query, which finds one
// without building URL.Query's map. A body of up to fit's streaming threshold
// arrives whole, Content-Length or chunked, before the handler runs, and is
// read where it lies through Context.Body; a larger one is no number this
// endpoint takes.
func (*Baseline) ServeHTTP(c *fibhttp.Context) {
	sum := queryInt(c.Query("a"), 0) + queryInt(c.Query("b"), 0)
	if c.Request.Method == stdhttp.MethodPost {
		if c.RequestBody() != nil {
			_ = c.Respond(stdhttp.StatusRequestEntityTooLarge, textPlain, nil)
			return
		}
		if n, err := strconv.Atoi(strings.TrimSpace(string(c.Body()))); err == nil {
			sum += n
		}
	}
	_ = c.Respond(stdhttp.StatusOK, textPlain, strconv.AppendInt(nil, int64(sum), 10))
}

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

// JSON answers /json/{count}?m=M with the dataset's first count items, each
// with total = price * quantity * m. The dataset is read once, when the
// config is loaded; the response is built and serialized for every request.
type JSON struct {
	Dataset string `json:"dataset,omitempty" default:"\"/data/dataset.json\"" doc:"The dataset file; /data/dataset.json when left out. A missing or unreadable one leaves the dataset empty."`
	Prefix  string `json:"prefix,omitempty" default:"\"/json/\"" doc:"The path before the count; /json/ when left out."`

	items []DatasetItem
}

func (j *JSON) Provision(*module.Context) error {
	if j.Dataset == "" {
		j.Dataset = "/data/dataset.json"
	}
	if j.Prefix == "" {
		j.Prefix = "/json/"
	}
	// A missing or unreadable dataset leaves the list empty, and fit still
	// starts, as the other entries do.
	if data, err := os.ReadFile(j.Dataset); err == nil {
		_ = json.Unmarshal(data, &j.items)
	}
	return nil
}

func (*JSON) Inline() {}

// ServeHTTP answers through Context.JSON, which encodes as json.Marshal does
// into a buffer fib recycles once the response is out.
func (j *JSON) ServeHTTP(c *fibhttp.Context) {
	count, err := strconv.Atoi(strings.TrimPrefix(c.Request.URL.Path, j.Prefix))
	if err != nil {
		_ = c.Respond(stdhttp.StatusBadRequest, textPlain, nil)
		return
	}
	count = min(max(count, 0), len(j.items))
	m := queryInt(c.Query("m"), 1)
	items := make([]ProcessedItem, count)
	for i := range items {
		d := j.items[i]
		items[i] = ProcessedItem{DatasetItem: d, Total: d.Price * d.Quantity * m}
	}
	if err := c.JSON(stdhttp.StatusOK, ProcessResponse{Items: items, Count: count}); err != nil {
		_ = c.Respond(stdhttp.StatusInternalServerError, textPlain, nil)
	}
}

func queryInt(v string, fallback int) int {
	if n, err := strconv.Atoi(v); err == nil {
		return n
	}
	return fallback
}
