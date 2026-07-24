---
title: Validation
---

The same `validate-ws.py` checks executed for the [Echo](../echo/validation/) profile apply here - pipelining is a load-generator behavior, not a separate server contract. The endpoint and frame semantics are identical, so a server that passes the Echo validation passes for Echo Pipelined as well.

See the [Echo validation page](../echo/validation/) for the full list of checks (handshake, accept header, text/binary echo, multi-message echo, clean close, non-upgrade rejection, post-validation health check).
