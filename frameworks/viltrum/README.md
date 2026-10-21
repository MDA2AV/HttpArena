# viltrum

[viltrum](https://github.com/Tuntii/viltrum) is an HTTP framework for V with its own HTTP/1.1 engine
(no stdlib `net.http` underneath). Docs: https://github.com/Tuntii/viltrum/tree/main/docs

This entry runs one process with one epoll loop per CPU (`epoll_cores`, `SO_REUSEPORT`), which is
why it is `tuned`: the framework default is thread-per-connection.

| Profile | Endpoint | Notes |
|---------|----------|-------|
| baseline, limited-conn | `GET/POST /baseline11` | query params via `req.query_param`, body via `req.body` (Content-Length or chunked) |
| pipelined | `GET /pipeline` | pipelined responses are batched into one write by the engine |
| json-comp | `GET /json/:count?m=` | `json.encode` per request, `viltrum.gzip` middleware |
| echo-ws | `/ws` | `app.ws`, viltrum's own WebSocket implementation |
