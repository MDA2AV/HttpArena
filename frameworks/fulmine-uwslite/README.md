# fulmine.js - uwsLite

fulmine.js with its routes written with `app.uwsLite`: `(req, res)` handlers that uWebSockets.js serves over two small objects, with no Express layer in front. It runs only the H/1.1 profiles that count for the score.

## Stack

- **Language:** JavaScript
- **Runtime:** Node.js 26
- **Framework:** [fulmine.js](https://github.com/nigrosimone/fulmine.js)
- **Build:** multi-stage, `node:26-trixie-slim` for both stages

## Endpoints

- `GET` and `POST /baseline11`: the sum of the query, and of the body
- `GET /delay/:ms`: answers after the wait
- `GET /json/:count?m=`: the dataset, compressed with brotli when asked
- `GET /json/:count` and `POST /echo` over TLS on 8081
