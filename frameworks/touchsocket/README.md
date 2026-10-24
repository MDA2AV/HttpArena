# touchsocket

[TouchSocket](https://github.com/RRQM/TouchSocket) — `TouchSocket.Http`, the HTTP/1.1 server
component of the TouchSocket networking framework.

Requests are answered from an `IHttpPlugin`, which is how TouchSocket exposes its HTTP pipeline:
the plugin sees each request, answers the ones it recognises and passes the rest along. Dispatch is
on the path's first segment — the component gives you the request, not a router to declare routes
with.

## Scope

HTTP/1.1 cleartext on `:8080`, plus the async delay.

| Profiles |
|---|
| baseline, pipelined, limited-conn, async, latency-1m, latency-10k, json-comp |

## Notes

- `/json` is serialized from the parsed model on **every** request and compressed only when the
  client asked for it, at brotli quality 1. Nothing is answered from a precomputed body.
- `/delay/{ms}` uses `Task.Delay`, which registers a timer and yields rather than holding a thread,
  so waits in flight are bounded by memory.
- The project is named `touchsocketarena` rather than `touchsocket`: a project named for the
  package it depends on makes NuGet resolve a dependency cycle on itself (NU1108).

## Status: disabled

The entry is `enabled: false` pending a fix in TouchSocket.

A request that arrives **split across TCP segments** *and* asks for `Connection: close` is answered
with nothing: the socket is closed instead of the response being flushed. The same requests pass at
every split offset when the connection is keep-alive, so it is the close path specifically, not
request reassembly.

Measured against `TouchSocket.Http` 4.3.6 on `.NET 10`, sweeping every split offset of one request:

| request | result |
|---------|--------|
| `Connection: keep-alive` | 54/54 offsets answered correctly |
| `Connection: close` | 20/73 offsets answered with nothing |

Repro — no framework beyond TouchSocket is involved, and the handler does no parsing of its own:

```python
import socket, time
req = b"GET /baseline11?a=13&b=42 HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
for split in (4, 34, 41):
    s = socket.create_connection(("127.0.0.1", 8080))
    s.sendall(req[:split]); time.sleep(0.01); s.sendall(req[split:])
    print(split, s.recv(4096)[:40])   # b'' on the failing offsets
    s.close()
```

The arena's fragmentation checks send exactly this shape, which is why they fail while ordinary
`curl` traffic does not.
