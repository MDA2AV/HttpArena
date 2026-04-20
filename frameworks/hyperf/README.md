# Hyperf

A coroutine framework that focuses on hyperspeed and flexibility. Building microservice or middleware with ease.

- https://github.com/hyperf/hyperf
- www.hyperf.io


## Stack

- **Language:** PHP
- **Engine:** Swoole


## Endpoints

| Endpoint             | Method    | Tests              |
|----------------------|-----------|--------------------|
| `/pipeline`          | GET       | `pipelined`        |
| `/baseline11`        | GET POST  | `baseline`         |
| `/json/{count}`      | GET       | `json` `json-comp` |
| `/async-db`          | GET       | `async-db`         |
| `/upload`            | POST      | `upload`           |
| `/static/{filename}` | GET       | `static`           |
| `/ws/`               | WEBSOCKET | `ws`               |


## Notes

When running the container, add the `--security-opt seccomp:unconfined` option to allow the Docker container to use io_uring features.
