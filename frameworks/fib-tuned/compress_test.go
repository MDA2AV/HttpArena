package main

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"testing"

	"github.com/klauspost/compress/flate"
	"github.com/klauspost/compress/gzip"
	"github.com/klauspost/compress/zstd"
	brrr "github.com/molecule-man/go-brrr"
)

func testCoders() *coders {
	return newCoders(CompressConfig{
		BrotliQuality: brrr.BestSpeed,
		ZstdLevel:     zstd.SpeedFastest,
		GzipLevel:     gzip.BestSpeed,
		DeflateLevel:  flate.BestSpeed,
		Prefer:        defaultPrefer,
	})
}

func decode(t *testing.T, name string, data []byte) []byte {
	t.Helper()
	var out []byte
	var err error
	switch name {
	case "br":
		out, err = brrr.Decompress(data)
	case "zstd":
		var d *zstd.Decoder
		if d, err = zstd.NewReader(nil); err == nil {
			out, err = d.DecodeAll(data, nil)
			d.Close()
		}
	case "gzip":
		var r *gzip.Reader
		if r, err = gzip.NewReader(bytes.NewReader(data)); err == nil {
			out, err = io.ReadAll(r)
		}
	case "deflate":
		out, err = io.ReadAll(flate.NewReader(bytes.NewReader(data)))
	}
	if err != nil {
		t.Fatalf("%s: decode: %v", name, err)
	}
	return out
}

// /json's bodies for every count, each coded through the same pooled buffers
// and writers many times over, decode to what went in, and stay under
// maxCopiedBody, so that the pool gets each buffer back.
func TestCodersRoundTrip(t *testing.T) {
	data, err := os.ReadFile("../../data/dataset.json")
	if err != nil {
		t.Skip(err)
	}
	var items []DatasetItem
	if err := json.Unmarshal(data, &items); err != nil {
		t.Fatal(err)
	}
	cs := testCoders()
	for _, c := range cs.list {
		largest := 0
		for round := 0; round < 3; round++ {
			for count := 0; count <= len(items); count++ {
				resp := ProcessResponse{Count: count}
				for _, d := range items[:count] {
					resp.Items = append(resp.Items, ProcessedItem{DatasetItem: d, Total: d.Price * d.Quantity * (round + 1)})
				}
				body, _ := json.Marshal(resp)
				buf := outBufs.Get().(*outBuf)
				buf.b = buf.b[:0]
				if !c.encode(buf, body) {
					if len(body) >= 1<<10 {
						t.Fatalf("%s: %d bytes did not compress", c.name, len(body))
					}
					outBufs.Put(buf)
					continue
				}
				if got := decode(t, c.name, buf.b); !bytes.Equal(got, body) {
					t.Fatalf("%s: count %d: round trip differs", c.name, count)
				}
				largest = max(largest, len(buf.b))
				outBufs.Put(buf)
			}
		}
		t.Logf("%s: largest /json body %d bytes", c.name, largest)
		if c.name == "br" && largest > maxCopiedBody {
			t.Errorf("br: /json/%d codes to %d bytes, past maxCopiedBody", len(items), largest)
		}
	}
}

func TestNegotiate(t *testing.T) {
	cs := testCoders()
	for _, tc := range []struct {
		fields []string
		want   string
	}{
		{[]string{"gzip, br"}, "br"},
		{[]string{"gzip, br"}, "br"},
		{[]string{"gzip"}, "gzip"},
		{[]string{"gzip, br;q=0.5"}, "gzip"},
		{[]string{"identity"}, ""},
		{[]string{"*;q=0.1, deflate"}, "deflate"},
		{[]string{"gzip", "zstd"}, "zstd"},
		{nil, ""},
		{[]string{"gzip, br"}, "br"},
	} {
		got := ""
		if c := cs.negotiate(tc.fields); c != nil {
			got = c.name
		}
		if got != tc.want {
			t.Errorf("negotiate(%q) = %q, want %q", tc.fields, got, tc.want)
		}
	}
}
