package main

import (
	"bytes"
	"io"
	stdhttp "net/http"
	"strconv"
	"strings"
	"sync"

	"github.com/andybalholm/brotli"
	"github.com/klauspost/compress/flate"
	"github.com/klauspost/compress/gzip"
	"github.com/klauspost/compress/zstd"
	fibhttp "github.com/lesismal/fib/http"
	"github.com/lesismal/fib/middleware"
)

// CompressConfig sets how hard each coding works and which bodies are worth
// it. Zero values take the defaults newCompress documents.
type CompressConfig struct {
	// MinLength is the shortest body compressed.
	MinLength int
	// BrotliQuality is 0-11, ZstdLevel one of zstd's EncoderLevels, and
	// GzipLevel and DeflateLevel are flate levels, 1-9.
	BrotliQuality int
	ZstdLevel     zstd.EncoderLevel
	GzipLevel     int
	DeflateLevel  int
	// Prefer orders the codings the server picks between when the client
	// weighs them the same, as "gzip, br" does. Codings left out follow in the
	// default order.
	Prefer []string
}

// defaultPrefer is the order measured to cost least for the bytes it saves on
// the JSON bodies here (25-50 items, 4-8 KB): gzip at level 6 makes them 81%
// smaller in about 17us, zstd about as small in a little less, and brotli
// only gets smaller than gzip from quality 5 on, by another 10% for four
// times the CPU. A client that asks for brotli by q value still gets it.
var defaultPrefer = []string{"gzip", "zstd", "br", "deflate"}

// newCompress is a compression middleware on fib's middleware API, doing what
// fib's own compress does - one OnResponse hook that sees the response whole -
// with brotli and zstd besides gzip and deflate. A response is compressed
// when its body is at least MinLength long, its Content-Type compresses, it
// carries no Content-Encoding of its own, is not partial and does not forbid
// transforming; a compressed body that comes out no shorter is sent as it was.
// Every response that could have been compressed says so in Vary.
//
// The coding is the one Accept-Encoding gives the highest q; between equals it
// is the first in Config.Prefer.
func newCompress(config CompressConfig) middleware.Middleware {
	if config.MinLength <= 0 {
		config.MinLength = 256
	}
	if config.BrotliQuality <= 0 {
		config.BrotliQuality = 5
	}
	if config.ZstdLevel == 0 {
		config.ZstdLevel = zstd.SpeedDefault
	}
	if config.GzipLevel == 0 {
		config.GzipLevel = gzip.DefaultCompression
	}
	if config.DeflateLevel == 0 {
		config.DeflateLevel = flate.DefaultCompression
	}
	if len(config.Prefer) == 0 {
		config.Prefer = defaultPrefer
	}
	codings := newCoders(config)
	return func(next fibhttp.Handler) fibhttp.Handler {
		return fibhttp.HandlerFunc(func(c *fibhttp.Context, r *stdhttp.Request) {
			coder := codings.negotiate(r.Header["Accept-Encoding"])
			head := r.Method == stdhttp.MethodHead
			c.OnResponse(func(response *fibhttp.Response) {
				if !compressible(response, config.MinLength) {
					return
				}
				middleware.AddVary(response.Header, "Accept-Encoding")
				if coder == nil || head {
					return
				}
				body, ok := coder.encode(response.Body)
				if !ok {
					return
				}
				response.Body = body
				response.Header["Content-Encoding"] = []string{coder.name}
				delete(response.Header, "Content-Length")
				if tag := headerValue(response.Header, "Etag"); tag != "" && !strings.HasPrefix(tag, "W/") {
					response.Header["Etag"] = []string{"W/" + tag}
				}
			})
			next.ServeHTTP(c, r)
		})
	}
}

// compressible reports whether response could be compressed for a client that
// accepts it. A response to HEAD counts by the length it declares.
func compressible(response *fibhttp.Response, minLength int) bool {
	status := response.StatusCode
	if status < 200 || status == stdhttp.StatusNoContent || status == stdhttp.StatusNotModified ||
		status == stdhttp.StatusPartialContent || response.Header == nil {
		return false
	}
	h := response.Header
	if encoding := headerValue(h, "Content-Encoding"); encoding != "" && encoding != "identity" {
		return false
	}
	if _, ok := h["Content-Range"]; ok {
		return false
	}
	for _, value := range h["Cache-Control"] {
		if strings.Contains(strings.ToLower(value), "no-transform") {
			return false
		}
	}
	length := len(response.Body)
	if length == 0 {
		if n, err := strconv.Atoi(headerValue(h, "Content-Length")); err == nil {
			length = n
		}
	}
	if length < minLength {
		return false
	}
	mediaType, _, _ := strings.Cut(headerValue(h, "Content-Type"), ";")
	mediaType = strings.ToLower(strings.TrimSpace(mediaType))
	return strings.HasPrefix(mediaType, "text/") || strings.HasSuffix(mediaType, "+json") ||
		strings.HasSuffix(mediaType, "+xml") || mediaType == "application/json" ||
		mediaType == "application/javascript" || mediaType == "application/xml" ||
		mediaType == "image/svg+xml"
}

func headerValue(h stdhttp.Header, name string) string {
	if values := h[name]; len(values) > 0 {
		return values[0]
	}
	return ""
}

// coder is one content coding. encode returns the coded body in an array of
// its own, since the response keeps it until it is sent, and false when coding
// failed or saved nothing.
type coder struct {
	name   string
	encode func(body []byte) ([]byte, bool)
}

// coders holds the codings in the server's order of preference.
type coders struct {
	list []*coder
}

// bufferPool holds the scratch buffers the stream coders write into; the
// result is copied out of them at its exact length.
var bufferPool = sync.Pool{New: func() any { return new(bytes.Buffer) }}

// streamCoder wraps a coder that writes through an io.WriteCloser which can be
// reset onto a new destination, recycling the writers, which cost far more to
// make than to reset.
func streamCoder(name string, make func() streamWriter) coder {
	writers := sync.Pool{New: func() any { return make() }}
	return coder{name: name, encode: func(body []byte) ([]byte, bool) {
		buf := bufferPool.Get().(*bytes.Buffer)
		buf.Reset()
		defer bufferPool.Put(buf)
		w := writers.Get().(streamWriter)
		w.Reset(buf)
		_, err := w.Write(body)
		if cerr := w.Close(); err == nil {
			err = cerr
		}
		writers.Put(w)
		if err != nil || buf.Len() >= len(body) {
			return nil, false
		}
		return bytes.Clone(buf.Bytes()), true
	}}
}

type streamWriter interface {
	io.WriteCloser
	Reset(io.Writer)
}

func newCoders(config CompressConfig) *coders {
	// A zstd encoder is safe for concurrent EncodeAll, keeping as many
	// states as GOMAXPROCS, and EncodeAll needs no stream around it, so one
	// serves every request.
	zenc, err := zstd.NewWriter(nil, zstd.WithEncoderLevel(config.ZstdLevel), zstd.WithZeroFrames(true))
	if err != nil {
		panic(err)
	}
	all := map[string]coder{
		"br": streamCoder("br", func() streamWriter {
			return brotli.NewWriterLevel(nil, config.BrotliQuality)
		}),
		"zstd": {name: "zstd", encode: func(body []byte) ([]byte, bool) {
			out := zenc.EncodeAll(body, make([]byte, 0, len(body)/2))
			return out, len(out) < len(body)
		}},
		"gzip": streamCoder("gzip", func() streamWriter {
			w, _ := gzip.NewWriterLevel(nil, config.GzipLevel)
			return w
		}),
		"deflate": streamCoder("deflate", func() streamWriter {
			w, _ := flate.NewWriter(nil, config.DeflateLevel)
			return w
		}),
	}
	cs := &coders{}
	for _, name := range config.Prefer {
		if c, ok := all[name]; ok {
			cs.list = append(cs.list, &c)
			delete(all, name)
		}
	}
	for _, name := range defaultPrefer {
		if c, ok := all[name]; ok {
			cs.list = append(cs.list, &c)
		}
	}
	return cs
}

// negotiate picks the coding the Accept-Encoding fields give the highest q,
// the first in the server's order among equals, or nil when they accept none.
func (cs *coders) negotiate(fields []string) *coder {
	if len(fields) == 0 {
		return nil
	}
	// q values by position in cs.list; -1 is not listed.
	var qs [4]float64
	q := qs[:len(cs.list)]
	for i := range q {
		q[i] = -1
	}
	anyQ := -1.0
	for _, field := range fields {
		for field != "" {
			var member string
			member, field, _ = strings.Cut(field, ",")
			name, params, _ := strings.Cut(member, ";")
			weight := 1.0
			for params != "" {
				var param string
				param, params, _ = strings.Cut(params, ";")
				if key, value, ok := strings.Cut(strings.TrimSpace(param), "="); ok && strings.EqualFold(key, "q") {
					if v, err := strconv.ParseFloat(strings.TrimSpace(value), 64); err == nil {
						weight = v
					}
				}
			}
			name = strings.TrimSpace(name)
			if name == "*" {
				anyQ = weight
				continue
			}
			if strings.EqualFold(name, "x-gzip") {
				name = "gzip"
			}
			for i, c := range cs.list {
				if strings.EqualFold(name, c.name) {
					q[i] = weight
				}
			}
		}
	}
	var best *coder
	bestQ := 0.0
	for i, v := range q {
		if v < 0 {
			v = anyQ
		}
		if v > bestQ {
			best, bestQ = cs.list[i], v
		}
	}
	return best
}
