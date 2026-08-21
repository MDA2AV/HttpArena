package main

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"io"
	"net/http"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"
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

// A missing or unreadable dataset leaves the list empty, the server still starts.
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

var bufPool = sync.Pool{New: func() any { return new(bytes.Buffer) }}

var gzipPool = sync.Pool{New: func() any {
	w, _ := gzip.NewWriterLevel(io.Discard, gzip.DefaultCompression)
	return w
}}

// The standard library has no compression middleware, so Accept-Encoding is
// parsed here: the gzip token counts only when its q value is above zero.
func acceptsGzip(header string) bool {
	for header != "" {
		part := header
		if i := strings.IndexByte(header, ','); i >= 0 {
			part, header = header[:i], header[i+1:]
		} else {
			header = ""
		}
		name, params, _ := strings.Cut(part, ";")
		if !strings.EqualFold(strings.TrimSpace(name), "gzip") {
			continue
		}
		for params != "" {
			var p string
			p, params, _ = strings.Cut(params, ";")
			p = strings.TrimSpace(p)
			if len(p) > 2 && strings.EqualFold(p[:2], "q=") {
				q, err := strconv.ParseFloat(p[2:], 64)
				return err != nil || q > 0
			}
		}
		return true
	}
	return false
}

func pipeline(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain")
	w.Write([]byte("ok"))
}

// Sum of every integer query parameter, plus the integer in the body on POST.
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
	count, _ := strconv.Atoi(r.PathValue("count"))
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

	buf := bufPool.Get().(*bytes.Buffer)
	buf.Reset()
	enc := json.NewEncoder(buf)
	if err := enc.Encode(ProcessResponse{Items: items, Count: count}); err != nil {
		bufPool.Put(buf)
		http.Error(w, "", http.StatusInternalServerError)
		return
	}
	body := bytes.TrimSuffix(buf.Bytes(), []byte("\n"))

	h := w.Header()
	h.Set("Content-Type", "application/json")
	if acceptsGzip(r.Header.Get("Accept-Encoding")) {
		out := bufPool.Get().(*bytes.Buffer)
		out.Reset()
		zw := gzipPool.Get().(*gzip.Writer)
		zw.Reset(out)
		_, werr := zw.Write(body)
		cerr := zw.Close()
		gzipPool.Put(zw)
		if werr == nil && cerr == nil {
			h.Set("Content-Encoding", "gzip")
			h.Set("Vary", "Accept-Encoding")
			h.Set("Content-Length", strconv.Itoa(out.Len()))
			w.Write(out.Bytes())
			bufPool.Put(out)
			bufPool.Put(buf)
			return
		}
		bufPool.Put(out)
	}
	h.Set("Content-Length", strconv.Itoa(len(body)))
	w.Write(body)
	bufPool.Put(buf)
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

// One goroutine per request over every core the cgroup allows: read the cpu
// quota the way koa's getCPUCount does and cap GOMAXPROCS with it, so a
// CPU-limited container does not schedule against cores it cannot use.
func limitProcsToCgroup() {
	quota, ok := cgroupCPUs()
	if ok && quota >= 1 && quota < runtime.NumCPU() {
		runtime.GOMAXPROCS(quota)
	}
}

func cgroupCPUs() (int, bool) {
	// cgroup v2: "<quota> <period>", or "max <period>" when unlimited.
	if data, err := os.ReadFile("/sys/fs/cgroup/cpu.max"); err == nil {
		fields := strings.Fields(string(data))
		if len(fields) == 2 && fields[0] != "max" {
			quota, err1 := strconv.Atoi(fields[0])
			period, err2 := strconv.Atoi(fields[1])
			if err1 == nil && err2 == nil && period > 0 {
				return quota / period, true
			}
		}
		return 0, false
	}
	// cgroup v1: quota and period in two separate files, -1 when unlimited.
	quota, err1 := readIntFile("/sys/fs/cgroup/cpu/cpu.cfs_quota_us")
	period, err2 := readIntFile("/sys/fs/cgroup/cpu/cpu.cfs_period_us")
	if err1 == nil && err2 == nil && quota > 0 && period > 0 {
		return quota / period, true
	}
	return 0, false
}

func readIntFile(path string) (int, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(strings.TrimSpace(string(data)))
}

func main() {
	limitProcsToCgroup()
	loadDataset()

	// Go 1.22 ServeMux: the method and the {count} wildcard are part of the pattern.
	mux := http.NewServeMux()
	mux.HandleFunc("GET /pipeline", pipeline)
	mux.HandleFunc("GET /baseline11", baseline11)
	mux.HandleFunc("POST /baseline11", baseline11)
	mux.HandleFunc("GET /json/{count}", jsonItems)
	mux.HandleFunc("POST /upload", upload)

	server := &http.Server{Addr: ":8080", Handler: mux}
	if err := server.ListenAndServe(); err != nil {
		os.Exit(1)
	}
}
