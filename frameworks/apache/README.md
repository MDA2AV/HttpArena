# apache

Stock Debian Apache HTTPD 2.4 with the event MPM and `mod_lua`. The
dynamic `/baseline11` handler is a short Lua script invoked via
`LuaMapHandler`; static files under `/static/` are served directly by
`mod_alias` + Apache core.

## Stack

- **Language:** C (Apache core) + Lua (handler)
- **Engine:** Apache HTTPD 2.4
- **MPM:** event (async keepalive)

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline11` | GET  | Sum of integer query args |
| `/baseline11` | POST | Sum of integer query args + integer body |
| `/static/{filename}` | GET | Serves files from `/data/static/` |

## Notes

- No custom C modules or source builds; everything comes from
  `apache2` + `libapache2-mod-lua` in Debian bookworm.
- `MaxRequestWorkers=1024` across up to 32 children (32 threads each).
  The event MPM keeps idle keepalive connections off worker threads,
  so 1024 in-flight slots comfortably cover the benchmark's 4096
  concurrent-connection ceiling.
- Access log disabled; `EnableMMAP`/`EnableSendfile` on for `/static/`.
