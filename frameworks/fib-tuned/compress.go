package main

import (
	"io"
	stdhttp "net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/klauspost/compress/flate"
	"github.com/klauspost/compress/gzip"
	"github.com/klauspost/compress/zstd"
	fibhttp "github.com/lesismal/fib/http"
	"github.com/lesismal/fib/middleware"
	brrr "github.com/molecule-man/go-brrr"
)

// CompressConfig sets how hard each coding works and which bodies are worth
// it. Zero values take the defaults newCompress documents, except
// BrotliQuality, whose zero is quality 0.
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

// defaultPrefer is fiber's compress middleware's order between codings a
// client weighs the same: brotli first, so "gzip, br" gets brotli.
var defaultPrefer = []string{"br", "zstd", "gzip", "deflate"}

// defaultMinLength is the shortest body fasthttp, under fiber's compress
// middleware, compresses (fasthttp's minCompressLen).
const defaultMinLength = 200

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
		config.MinLength = defaultMinLength
	}
	config.BrotliQuality = min(max(config.BrotliQuality, brrr.BestSpeed), brrr.BestCompression)
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
		return fibhttp.HandlerFunc(func(c *fibhttp.Context) {
			r := c.Request
			coder := codings.negotiate(r.Header["Accept-Encoding"])
			head := r.Method == stdhttp.MethodHead
			// out is the pooled buffer the body was coded into, while the
			// response may still be reading it.
			var out *outBuf
			c.OnResponse(func(response *fibhttp.Response) {
				if !compressible(response, config.MinLength) {
					return
				}
				middleware.AddVary(response.Header, "Accept-Encoding")
				if coder == nil || head {
					return
				}
				buf := outBufs.Get().(*outBuf)
				buf.b = buf.b[:0]
				if !coder.encode(buf, response.Body) {
					outBufs.Put(buf)
					return
				}
				response.Body = buf.b
				if r.ProtoMajor == 1 && len(buf.b) <= maxCopiedBody {
					out = buf
				}
				// Otherwise the response keeps the array, and the pool
				// makes another.
				response.Header["Content-Encoding"] = []string{coder.name}
				delete(response.Header, "Content-Length")
				if tag := headerValue(response.Header, "Etag"); tag != "" && !strings.HasPrefix(tag, "W/") {
					response.Header["Etag"] = []string{"W/" + tag}
				}
			})
			if coder != nil && !head && r.ProtoMajor == 1 {
				c.OnFinish(func(int, stdhttp.Header, int64) {
					if out != nil {
						outBufs.Put(out)
						out = nil
					}
				})
			}
			next.ServeHTTP(c)
		})
	}
}

// maxCopiedBody is the longest body fib's HTTP/1 send copies into the
// connection's buffer, so that the array is free again once the response has
// been handed over and its OnFinish hooks run (fib v1.8.0's
// maxCopiedResponseBody, in http/handler.go). A longer body is sent from the
// array itself, which the connection may keep until the socket has taken
// it, so it is not given back to the pool. HTTP/2 and HTTP/3 keep the body
// until flow control or the peer's acknowledgement lets it go, so theirs
// never are. A compressed /json/50 is under 2 KB.
const maxCopiedBody = 4 << 10

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

// coder is one content coding. encode appends the coded body to dst, and
// reports false when coding failed or saved nothing.
type coder struct {
	name   string
	encode func(dst *outBuf, body []byte) bool
}

// coders holds the codings in the server's order of preference, and the
// last Accept-Encoding negotiated with what it chose.
type coders struct {
	list []*coder
	last atomic.Pointer[negotiation]
}

type negotiation struct {
	field string
	coder *coder
}

// outBuf is the array a body is coded into. Its Write appends, so that the
// stream coders can write to it; the one-shot ones append to b.
type outBuf struct {
	b []byte
}

func (o *outBuf) Write(p []byte) (int, error) {
	o.b = append(o.b, p...)
	return len(p), nil
}

// outBufs holds the arrays coded bodies are written to, given back once
// their response no longer reads them.
var outBufs = sync.Pool{New: func() any { return &outBuf{b: make([]byte, 0, maxCopiedBody)} }}

// streamCoder wraps a coder that writes through an io.WriteCloser which can be
// reset onto a new destination, recycling the writers, which cost far more to
// make than to reset.
func streamCoder(name string, make func() streamWriter) coder {
	writers := sync.Pool{New: func() any { return make() }}
	return coder{name: name, encode: func(dst *outBuf, body []byte) bool {
		w := writers.Get().(streamWriter)
		w.Reset(dst)
		_, err := w.Write(body)
		if cerr := w.Close(); err == nil {
			err = cerr
		}
		writers.Put(w)
		return err == nil && len(dst.b) < len(body)
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
	// go-brrr, the brotli encoder fasthttp, and so fiber-tuned, uses. Its
	// Writers are recycled as its one-shot Compress recycles its encoders,
	// and told the body's length up front as Compress is, but write into
	// outBuf rather than into an array Compress makes for each body.
	brWriters := sync.Pool{New: func() any {
		w, err := brrr.NewWriter(nil, config.BrotliQuality)
		if err != nil {
			panic(err)
		}
		return w
	}}
	all := map[string]coder{
		"br": {name: "br", encode: func(dst *outBuf, body []byte) bool {
			w := brWriters.Get().(*brrr.Writer)
			w.ResetWithSizeHint(dst, uint(len(body)))
			_, err := w.Write(body)
			if cerr := w.Close(); err == nil {
				err = cerr
			}
			brWriters.Put(w)
			return err == nil && len(dst.b) < len(body)
		}},
		"zstd": {name: "zstd", encode: func(dst *outBuf, body []byte) bool {
			dst.b = zenc.EncodeAll(body, dst.b)
			return len(dst.b) < len(body)
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

// negotiate is parse with the last answer kept: clients send the same
// Accept-Encoding over and over, so a request whose one field is the last
// one parsed is answered without parsing it again.
func (cs *coders) negotiate(fields []string) *coder {
	if len(fields) != 1 {
		return cs.parse(fields)
	}
	if last := cs.last.Load(); last != nil && last.field == fields[0] {
		return last.coder
	}
	c := cs.parse(fields)
	// The field may be in the request's recycled buffer, so the key is a
	// copy of its own.
	cs.last.Store(&negotiation{field: strings.Clone(fields[0]), coder: c})
	return c
}

// parse picks the coding the Accept-Encoding fields give the highest q, the
// first in the server's order among equals, or nil when they accept none.
func (cs *coders) parse(fields []string) *coder {
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
