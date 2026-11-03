# hidi

C++20 HTTP/2 client and server library built on coroutines ([kelcoro](https://github.com/kelbon/kelcoro)) over Boost.Asio, with TLS via AWS-LC.

## Stack

- **Language:** C++20
- **Engine:** hidi
- **Build:** `ubuntu:24.04`, clang 18, `-O3 -march=native`; hidi's CMake fetches its dependencies with CPM

## Listeners

| Port | Protocols | Profiles |
|------|-----------|----------|
| 8443 | h2 (TLS, ALPN) | baseline-h2 |
| 8082 | h2c (prior knowledge) | baseline-h2c |

hidi implements HTTP/2 only, so there is no HTTP/1.1 listener on 8080. Each listener gets one thread per CPU in the process affinity mask; only one profile runs at a time.

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/baseline2` | GET | Sums query parameter values, `text/plain` |
