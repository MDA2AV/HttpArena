# mojolicious

Mojolicious on its own prefork server, default configuration.

## Stack

- **Language:** Perl 5.42
- **Framework:** [Mojolicious 9](https://github.com/mojolicious/mojo) on Mojo::Server::Prefork
- **Build:** Multi-stage on `perl:5.42.0-slim-bookworm`

## Endpoints

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/pipeline` | GET | Returns `ok` (plain text) |
| `/baseline11` | GET | Sums query parameter values |
| `/baseline11` | POST | Sums query parameters + request body |
| `/json/{count}?m=N` | GET | First `count` dataset items with `total = price * quantity * m` |
| `/upload` | POST | Counts the bytes of the request body |

## Notes

- Routing and path parameters through Mojolicious::Lite, JSON through Mojo::JSON.
- Compression is the renderer's own gzip negotiation, which is on by default, so
  json-comp is standard Mojolicious and nothing is hand rolled.
- Mojo::Server::Prefork is the server hypnotoad runs, without the hot deployment
  part a container does not need. One worker per available core, as each worker
  has a single event loop. EV is installed so the loop uses epoll.
- The request body is counted as it arrives instead of being buffered, otherwise
  the 20 MB upload bodies would be kept in memory and then spooled to a temp file.
- Two server limits are raised because they recycle connections and workers in the
  middle of a run: `max_requests` (100 by default, and the profiles reuse one
  connection for the whole run) and `accepts` (10000 by default, which restarts
  every worker several times under limited-conn). `max_clients` is 4096 so the
  16384 connections of json-comp fit above the 1000 per worker the event loop
  allows by default.
- The dataset is read once in the manager, so the workers share it copy on write.
  A missing file leaves an empty list and the server still answers.
