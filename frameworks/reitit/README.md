# reitit

Reitit 0.9 routing on Ring, served by the Jetty adapter.

## Stack

- **Language:** Clojure 1.12
- **Framework:** reitit-ring 0.9 + ring-jetty-adapter 1.15
- **Build:** `clojure:tools-deps-trixie-slim`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Reads the body in 64 KB chunks and returns the byte count |

The same routes are served over TLS on port 8081 for `json-tls`.

## Notes

- Routing through `reitit.ring/router` with a `:count` path parameter, which is
  what this entry exists to measure — reitit is a router, not a server
- `wrap-params` is attached as router `:data` middleware rather than wrapping the
  whole handler, so query parsing runs through reitit's own middleware chain
- JSON through `clojure.data.json`; the response is built with `array-map` so the
  field order is fixed to what the profile expects rather than left to hash order
- gzip for `json-comp` through Jetty's `GzipHandler`
- Uploads are counted through one 64 KB buffer rather than being read into memory
- The dataset is a `delay` read once on first use, then only read; a missing or
  broken file is not fatal and `/json` answers with an empty list
- json-tls on 8081 uses the same handler. The harness mounts PEMs and Jetty wants
  a KeyStore, so the pair is converted with the plain JDK classes rather than
  pulling in a crypto library for it
- A missing `/certs` leaves the TLS listener down instead of aborting startup:
  `validate.sh` mounts the directory only for entries subscribed to a TLS test
