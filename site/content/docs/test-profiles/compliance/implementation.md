---
title: Implementation Guidelines
seo_title: "Compliance: The /spec Route Contract"
description: "The /spec contract: GET, HEAD, OPTIONS and POST on one route plus a header echo, served on every HTTP/1.1 and HTTP/2 listener the entry runs."
---
{{< type-rules standard="Through the framework's normal routing, request body and header APIs, on the same listeners, parser and middleware as the benchmarked routes." tuned="Same as standard. Nothing on this route is measured, so there is nothing to tune." engine="Same contract. The route has to sit behind the same parser as the benchmarked routes: validating more strictly on /spec than on /baseline11 would score compliance for code the benchmark never runs." infrastructure="A proxy may answer /spec itself or pass it through to an origin. Either way the contract holds at the listener the suites connect to." >}}

One route, needed by the `h1` and `h2` suites in the `spec` list of `meta.json`, on every listener those suites use:

| Port | Protocol | Required when |
|---|---|---|
| 8080 | HTTP/1.1 | `spec` lists `h1` |
| 8443 | HTTP/2 over TLS | `spec` lists `h2` and the entry runs `baseline-h2` or `static-h2` |
| 8082 | HTTP/2 cleartext | `spec` lists `h2` and the entry runs `baseline-h2c` or `json-h2c` |

## The contract

| Request | Response |
|---|---|
| `GET /spec` | `200`, `text/plain`, a fixed body of at least 5 bytes |
| `HEAD /spec` | `200`, the headers `GET /spec` would send, no body |
| `OPTIONS /spec` | `200` with `Allow: GET, HEAD, POST, OPTIONS`. A request body, if one is sent, is read and discarded |
| `POST /spec` | `200`, `application/octet-stream`, the request body byte for byte |
| `GET /spec/headers`, `POST /spec/headers` | `200`, `text/plain`, every request header received, one per line as `Name: Value`. A request body is read and discarded |

```
GET /spec HTTP/1.1                    HTTP/1.1 200 OK
Host: localhost:8080                  Content-Type: text/plain
                                      Content-Length: 7

                                      spec ok
```

```
POST /spec HTTP/1.1                   HTTP/1.1 200 OK
Host: localhost:8080                  Content-Type: application/octet-stream
Content-Length: 11                    Content-Length: 11

hello world                           hello world
```

```
GET /spec/headers HTTP/1.1            HTTP/1.1 200 OK
Host: localhost:8080                  Content-Type: text/plain
X-Example: 1
                                      Host: localhost:8080
                                      X-Example: 1
```

### POST /spec

The bytes that arrived, unchanged, whatever they are: `Content-Length` or chunked framing, any size including empty (`200` with an empty body), with or without a `Content-Type` on the request. It is the same echo as the [8gbit profile's `/echo`](../h1/8gbit/implementation/), on another route and on every listener.

The body has to be read through the framework's normal body API. Most of the probe's framing tests - conflicting `Content-Length` and `Transfer-Encoding`, malformed chunk sizes, bodies that hide a second request - only mean something when the server actually reads the body. A route that never touches it can let through a malformed request that a reading route would have rejected.

### GET and HEAD

The content of the `GET` body does not matter, its length does: h2spec skips one of its flow-control tests when the response body is shorter than 5 bytes. The reference implementation answers `spec ok`.

`HEAD` must send no body. Many frameworks route `HEAD` to the `GET` handler and drop the body on their own; some need `HEAD` mapped explicitly.

### OPTIONS

`200` with an `Allow` header. One of the probe's smuggling tests sends `OPTIONS` with conflicting framing headers and a body, and needs the route to accept the method rather than answer `405`.

### /spec/headers

The request headers as the server stored them, one line each as `Name: Value`, in any order, with names in whatever case the framework keeps them. Repeated fields may be listed once per value or comma-joined, the way the framework exposes them.

The probe's normalization tests send a malformed header name - `Content_Length`, `Content-Length :`, a tab inside the name - and read this back to see what the server did with it: rejected it, dropped it, kept it as sent, or merged it into the real `Content-Length`. Only the last one is a failure.

## Everything goes through the normal pipeline

`/spec` has to be served by the same listener, parser and middleware as the benchmarked routes. Nothing on it is measured, so there is nothing to optimise - but a parser that is strict on `/spec` and lenient on `/baseline11` would earn a compliance score for code the benchmark never runs. The compliance run will also send the probe's route-independent tests (malformed request lines, header syntax) to `/baseline11` and flag an entry whose verdicts differ between the two routes.

## What does not need /spec

- **`h3`**: h3spec has no path setting. It sends malformed QUIC and HTTP/3 traffic and checks the error code the server closes the stream or connection with.
- **`ws`**: Autobahn runs against the existing `/ws` echo.
- **HTTP/1.1 over TLS** (port 8081) is not probed, so `/spec` is not required there.

## Try it

```bash
curl -i http://localhost:8080/spec
curl -I http://localhost:8080/spec
curl -i -X OPTIONS http://localhost:8080/spec
curl --data-binary 'hello world' http://localhost:8080/spec
curl -H 'X-Example: 1' http://localhost:8080/spec/headers
curl -sk --http2 --data-binary 'hello world' https://localhost:8443/spec
```
