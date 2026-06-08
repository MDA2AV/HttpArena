---
title: Validation
---

The following checks are executed by `validate.sh` for every framework subscribed to the `static-h2` test. The HTTPS port (8443) must be responding before checks begin.

## Content-Type headers

Verifies correct `Content-Type` headers for representative file types over HTTPS with HTTP/2:

- `GET /static/reset.css` - expects `Content-Type: text/css`
- `GET /static/app.js` - expects `Content-Type: application/javascript`
- `GET /static/manifest.json` - expects `Content-Type: application/json`

Note: `text/javascript` is accepted as equivalent to `application/javascript` per RFC 9239.

## Response size

Requests `GET /static/reset.css` over HTTP/2 and verifies the response size is greater than 0 bytes. This confirms the server is actually serving file content, not empty responses.

## 404 for nonexistent file

Sends `GET /static/nonexistent.txt` over HTTP/2 and verifies the server returns **HTTP 404**.
