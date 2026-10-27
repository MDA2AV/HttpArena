package main

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"errors"
	"io"
	"log"
	"net/http"
	_ "net/http/pprof"
	"os"
	"os/signal"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/andybalholm/brotli"
	"github.com/linfeip/fnet"
	"github.com/linfeip/fnet/fhttp"
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

// router dispatches on the request path with a switch instead of through
// http.ServeMux. The routes are a fixed handful, so the switch is a few
// comparisons where the mux walks its pattern trees; it also hands each
// handler its path parameter as a plain substring (the count of /json/{count},
// the delay of /delay/{ms}) rather than having the mux resolve it into
// Request.PathValue. Both matter per request: this Handler runs on every
// request of the baseline, pipelined, limited-conn, json-comp and async
// profiles.
//
// The answers match what the mux gave: GET and HEAD are served by the same
// handlers (HEAD keeps the Content-Length, fhttp drops the body), a known path
// with any other method is 405 with Allow, and anything else is 404.
type router struct{}

func (router) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	switch p := r.URL.Path; p {
	case "/baseline11", "/baseline2": // /baseline2 is the short alias of the readiness probes
		switch r.Method {
		case http.MethodGet, http.MethodHead, http.MethodPost:
			baseline11(w, r)
		default:
			methodNotAllowed(w, "GET, HEAD, POST")
		}
	case "/pipeline":
		switch r.Method {
		case http.MethodGet, http.MethodHead:
			pipeline(w)
		default:
			methodNotAllowed(w, "GET, HEAD")
		}
	case "/echo":
		if r.Method != http.MethodPost {
			methodNotAllowed(w, "POST")
			return
		}
		echoBody(w, r)
	default:
		if count, ok := strings.CutPrefix(p, "/json/"); ok && isSegment(count) {
			if r.Method != http.MethodGet && r.Method != http.MethodHead {
				methodNotAllowed(w, "GET, HEAD")
				return
			}
			jsonItems(w, r, count)
			return
		}
		if ms, ok := strings.CutPrefix(p, "/delay/"); ok && isSegment(ms) {
			if r.Method != http.MethodGet && r.Method != http.MethodHead {
				methodNotAllowed(w, "GET, HEAD")
				return
			}
			delay(w, ms)
			return
		}
		http.NotFound(w, r)
	}
}

// isSegment reports whether s is one non-empty path segment, which is all a
// single {name} wildcard of the mux matched: "/json/" and "/json/25/" are not
// routes.
func isSegment(s string) bool {
	return s != "" && !strings.Contains(s, "/")
}

func methodNotAllowed(w http.ResponseWriter, allow string) {
	w.Header().Set("Allow", allow)
	w.WriteHeader(http.StatusMethodNotAllowed)
}

// baseline11 sums every integer query parameter, plus the integer body of a
// POST. The query is walked in place: r.URL.Query would build a map of all of
// it for a Handler that only adds the values up, an allocation per request.
func baseline11(w http.ResponseWriter, r *http.Request) {
	sum := 0
	fhttp.ForEachQuery(r, func(_, value string) bool {
		if n, err := strconv.Atoi(value); err == nil {
			sum += n
		}
		return true
	})
	if r.Method == http.MethodPost {
		body, err := fhttp.RequestBody(r) // the buffered body itself, not a copy
		if err == nil {
			sum += atoi(body)
		}
	}
	writeSum(w, sum)
}

// writeSum writes sum as text/plain, formatting it into a stack buffer so that
// nothing of the response is allocated.
func writeSum(w http.ResponseWriter, sum int) {
	w.Header().Set("Content-Type", "text/plain")
	var buf [24]byte
	w.Write(strconv.AppendInt(buf[:0], int64(sum), 10))
}

func pipeline(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "text/plain")
	io.WriteString(w, "ok") // fhttp's response has WriteString: the literal is not copied
}

func delay(w http.ResponseWriter, msStr string) {
	ms, err := strconv.Atoi(msStr)
	if err != nil || ms < 0 {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	if ms > 0 {
		time.Sleep(time.Duration(ms) * time.Millisecond)
	}
	writeSum(w, ms)
}

// jsonItems serializes the first count items per request. When the client
// accepts gzip or brotli the response is compressed; fhttp has no compression
// middleware of its own, so the standard library's gzip and the established
// brotli library do the encoding the client asked for.
func jsonItems(w http.ResponseWriter, r *http.Request, countStr string) {
	count, _ := strconv.Atoi(countStr)
	if count < 0 {
		count = 0
	}
	if count > len(dataset) {
		count = len(dataset)
	}
	m, err := strconv.Atoi(fhttp.QueryParam(r, "m")) // like URL.Query().Get without the map
	if err != nil || m == 0 {
		m = 1
	}

	items := make([]ProcessedItem, count)
	for i := 0; i < count; i++ {
		d := dataset[i]
		items[i] = ProcessedItem{DatasetItem: d, Total: d.Price * d.Quantity * m}
	}
	body, err := json.Marshal(ProcessResponse{Items: items, Count: count})
	if err != nil {
		w.WriteHeader(http.StatusInternalServerError)
		return
	}

	switch acceptedEncoding(r) {
	case "br":
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Content-Encoding", "br")
		bw := brotliWriters.Get().(*brotli.Writer)
		bw.Reset(w)
		_, _ = bw.Write(body)
		_ = bw.Close()
		brotliWriters.Put(bw)
	case "gzip":
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Content-Encoding", "gzip")
		gw := gzipWriters.Get().(*gzip.Writer)
		gw.Reset(w)
		_, _ = gw.Write(body)
		_ = gw.Close()
		gzipWriters.Put(gw)
	default:
		w.Header().Set("Content-Type", "application/json")
		w.Write(body)
	}
}

// Compression writers are pooled, and the levels match what fasthttp's
// CompressHandlerBrotliLevel uses by default (brotli quality 4, gzip 6), so
// the json-comp comparison measures the same work on both sides. Creating a
// brotli writer per request allocates its encoder state every time and drops
// json-comp to a few tens of thousands of requests per second.
var (
	brotliWriters = sync.Pool{New: func() any {
		return brotli.NewWriterLevel(io.Discard, 4)
	}}
	gzipWriters = sync.Pool{New: func() any { return gzip.NewWriter(io.Discard) }}
)

// acceptedEncoding returns the encoding to answer with: "gzip" or "br", or ""
// when the request accepts neither. At equal q values gzip wins, because the
// two produce nearly identical bodies on these payloads (1490 vs 1519 bytes
// for /json/50?m=6) while brotli quality 4 costs several times gzip's CPU - on
// json-comp it is 76% of the server's samples against flate's 31% on the
// gzip-only entries. A client that asks for brotli by q value still gets it.
func acceptedEncoding(r *http.Request) string {
	header := r.Header.Get("Accept-Encoding")
	if header == "" {
		return ""
	}
	var gzipQ, brotliQ float64
	for header != "" {
		var part string
		part, header, _ = strings.Cut(header, ",")
		name := strings.TrimSpace(part)
		q := 1.0
		if i := strings.IndexByte(name, ';'); i >= 0 {
			params := name[i+1:]
			name = strings.TrimSpace(name[:i])
			for params != "" {
				var param string
				param, params, _ = strings.Cut(params, ";")
				param = strings.TrimSpace(param)
				if v, ok := strings.CutPrefix(param, "q="); ok {
					if f, err := strconv.ParseFloat(strings.TrimSpace(v), 64); err == nil {
						q = f
					}
				}
			}
		}
		switch strings.ToLower(name) {
		case "gzip":
			gzipQ = q
		case "br":
			brotliQ = q
		}
	}
	switch {
	case gzipQ > 0 && gzipQ >= brotliQ:
		return "gzip"
	case brotliQ > 0:
		return "br"
	}
	return ""
}

func echoBody(w http.ResponseWriter, r *http.Request) {
	body, err := fhttp.RequestBody(r)
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Write(body)
}

// atoi parses the integer in b as strconv.Atoi on its string would, returning 0
// where Atoi returns an error; a body of up to 18 digits is summed in place, so
// the common case allocates nothing.
func atoi(b []byte) int {
	b = bytes.TrimSpace(b)
	if len(b) == 0 || len(b) > 18 {
		n, err := strconv.Atoi(string(b))
		if err != nil {
			return 0
		}
		return n
	}
	n := 0
	for _, c := range b {
		if c < '0' || c > '9' { // a sign or anything else: let strconv judge it
			v, err := strconv.Atoi(string(b))
			if err != nil {
				return 0
			}
			return v
		}
		n = n*10 + int(c-'0')
	}
	return n
}

func main() {
	loadDataset()

	// Opt-in profiling: off unless PPROF_ADDR is set, so the measured version
	// is the same code either way. PPROF_BLOCK additionally turns on block and
	// mutex sampling, which is what shows waiting (not just burning CPU).
	if pprofAddr := os.Getenv("PPROF_ADDR"); pprofAddr != "" {
		if os.Getenv("PPROF_BLOCK") != "" {
			runtime.SetBlockProfileRate(100000) // sample blocking events >= 100µs
			runtime.SetMutexProfileFraction(100)
		}
		go func() {
			if err := http.ListenAndServe(pprofAddr, nil); err != nil {
				log.Printf("pprof listener %s: %v", pprofAddr, err)
			}
		}()
	}

	addr := os.Getenv("FNET_H1_ADDR")
	if addr == "" {
		addr = ":8080"
	}
	server, err := fhttp.NewServer(addr, router{}, fhttp.Options{
		// ReusePort gives every loop a listening socket of its own, sharing
		// the port through SO_REUSEPORT, so on Linux the kernel spreads the
		// connections over the loops instead of feeding them from one listener.
		// NoDelay is off unless FNET_H1_NODELAY is set, so the default entry
		// keeps fnet's default Nagle behaviour.
		Engine: fnet.Options{ReusePort: true, NoDelay: os.Getenv("FNET_H1_NODELAY") != ""},
	})
	if err != nil {
		log.Fatal(err)
	}

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-stop
		_ = server.Close()
	}()

	if err := server.Serve(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatal(err)
	}
}
