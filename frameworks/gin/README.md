# Gin

[Gin](https://github.com/gin-gonic/gin) is a Go web framework with a martini-like API, featuring the fastest HTTP router (httprouter) and zero-allocation routing.

## Implementation

- Uses Gin v1.10.0 in release mode with no middleware
- SQLite via `modernc.org/sqlite` (pure Go, no CGO)
- Manual deflate/gzip compression for the `/compression` endpoint
- Static files pre-loaded into memory at startup
- Listens on `:8080`
