---
title: Validation
seo_title: "Short-lived WebSocket Connection Benchmark: Validation Checks"
description: "The short-lived WebSocket profile is validated by the same validate-ws.py checks as the Echo profile; the message limit is a load-generator behaviour."
---

The same `validate-ws.py` checks executed for the [Echo](../echo/validation/) profile apply here. Closing a connection after 10 messages is a load-generator behaviour, not a separate server contract: the endpoint, the framing and the expected echo are identical.

`scripts/validate.sh` runs those checks for any framework subscribed to `echo-ws`, `echo-ws-pipeline` **or** `echo-ws-limited`, so subscribing to this profile alone is enough to have the WebSocket endpoint validated.

The behaviour specific to this profile, a fresh handshake for every connection, is exercised during the benchmark run rather than by a dedicated check. A server that only answers the first handshake correctly, or that reuses a precomputed `Sec-WebSocket-Accept`, fails every subsequent upgrade and reports a throughput near zero.
