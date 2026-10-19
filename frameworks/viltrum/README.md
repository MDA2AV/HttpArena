# viltrum

[viltrum](https://github.com/Tuntii/viltrum) is an HTTP framework for V with its own HTTP/1.1 engine
(no stdlib `net.http` underneath). Docs: https://github.com/Tuntii/viltrum/tree/main/docs

This entry runs viltrum with its default configuration (standard mode).

| Profile | Endpoint | Notes |
|---------|----------|-------|
| baseline, limited-conn | `GET/POST /baseline11` | `c.query_int`, `c.body_int` (Content-Length or chunked) |
| pipelined | `GET /pipeline` | the engine batches pipelined responses into one write |
| json-comp | `GET /json/:count?m=` | `c.json` per request, `viltrum.gzip` middleware |

The entry is typed `experimental`: viltrum's first commit is from July 2026, so it is new work
that has not proved itself in production yet, which is what that tier is for.
