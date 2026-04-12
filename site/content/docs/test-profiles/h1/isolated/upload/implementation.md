---
title: Implementation Guidelines
---
{{< type-rules production="Must use the framework standard body reading API. Streaming is allowed if the framework supports it natively." tuned="May use custom buffer sizes, direct socket reads, or bypass framework body parsing for maximum throughput." engine="No specific rules." >}}


The Upload profile measures how efficiently a framework handles large request body ingestion. The benchmark rotates across four payload sizes: 500 KB, 2 MB, 10 MB, and 20 MB. The server returns the byte count.

**Connections:** 32, 256

## How it works

1. The load generator sends `POST /upload` with a binary body (500 KB, 2 MB, 10 MB, or 20 MB) using pre-built raw request files, rotating every 5 requests
2. The server reads the entire request body
3. Returns the total number of bytes received as plain text

## What it measures

- **Request body ingestion throughput** - reading large payloads from the network
- **Memory management** - buffering 20 MB per concurrent request
- **I/O handling efficiency** - how the framework manages sustained large transfers
- **Connection overhead** - at 20 MB per request, connection setup/teardown is significant

## Implementation rules

The upload endpoint must actually read and process the request body. The returned byte count must be computed by reading the uploaded data, not inferred from request metadata.

- **Do not** return the value of the `Content-Length` header - this defeats the purpose of the test, which is to measure how efficiently the framework processes uploaded content.
- Frameworks **may** use small read buffers to process the upload incrementally. Holding the entire payload in memory is allowed but not required.
- The goal is to prove that the framework can efficiently compute a result over a large blob being sent to it.

## Expected response

```
POST /upload HTTP/1.1
Content-Length: 20971520
```

```
HTTP/1.1 200 OK
Content-Type: text/plain

20971520
```

## Parameters

| Parameter | Value |
|-----------|-------|
| Endpoint | `POST /upload` |
| Connections | 32, 256 |
| Pipeline | 1 |
| Duration | 5s |
| Runs | 3 (best taken) |
| Payloads | 500 KB, 2 MB, 10 MB, 20 MB (rotated with `-r 5`) |

## Notes

- I/O is the primary bottleneck - body ingestion dominates request handling time
- Lower connection counts are used because each request transfers 20 MB
- The load generator's bandwidth metric only measures response data (~8 bytes), not the uploaded payload
