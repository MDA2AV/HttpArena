# Woo — Common Lisp HTTP Server

[Woo](https://github.com/fukamachi/woo) is a fast, non-blocking HTTP server for Common Lisp, built on [libev](http://software.schmorp.de/pkg/libev.html). It runs on [SBCL](http://www.sbcl.org/) (Steel Bank Common Lisp), which compiles to native machine code.

## Why Woo?

- **First Lisp-family entry** in HttpArena
- Built on libev for non-blocking I/O with multi-worker process model
- SBCL compiles CL to native code — no interpreter overhead
- Solo developer [@fukamachi](https://github.com/fukamachi) has maintained it since 2014
- Uses the [Lack](https://github.com/fukamachi/lack)/[Clack](https://github.com/fukamachi/clack) interface — the Common Lisp equivalent of Ruby's Rack or Python's WSGI

## Architecture

- **Runtime:** SBCL (native compiled)
- **Event loop:** libev (non-blocking)
- **Workers:** Multi-process (one per CPU core)
- **JSON:** [Jonathan](https://github.com/Rudolph-Miller/jonathan) (fast JSON encoder/decoder)
- **Compression:** [Salza2](https://www.xach.com/lisp/salza2/) (gzip)
- **SQLite:** [cl-sqlite](https://github.com/dmitryvk/cl-sqlite)

## Build

The Docker build compiles everything into a standalone SBCL image (~50-80 MB compressed) that includes the full Lisp runtime and all dependencies. No Quicklisp needed at runtime.

```bash
docker build -t httparena-woo .
docker run -p 8080:8080 -v /path/to/data:/data httparena-woo
```
