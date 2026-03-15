# handy-httpd

An extremely lightweight HTTP server for the [D programming language](https://dlang.org/).

- **Language:** D
- **Repository:** https://github.com/andrewlalis/handy-httpd
- **Stars:** ~36
- **Compiler:** LDC2 (LLVM-based D compiler)

## About

handy-httpd is a solo-dev passion project by [@andrewlalis](https://github.com/andrewlalis), maintained since 2021. It provides a clean, composable API with routing via `PathHandler`, WebSocket support, and middleware via filters — all while staying extremely lightweight.

D compiles to native code via LLVM (LDC) and offers manual memory management with optional GC, making it an interesting performance data point between C/C++ and higher-level languages.

## Build

```bash
docker build -t httparena-handy-httpd .
```
