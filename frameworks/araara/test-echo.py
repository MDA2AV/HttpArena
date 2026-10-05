#!/usr/bin/env python3
"""Exercise a running arena image's binary echo over HTTP/1.1 and TLS.

Usage: python3 test-echo.py [https://localhost:8081]
Uses only the Python standard library. The benchmark certificate is self-signed.
"""

import http.client
import os
import ssl
import sys
from urllib.parse import urlsplit


def main():
    url = urlsplit(sys.argv[1] if len(sys.argv) > 1 else "https://localhost:8081")
    if url.scheme == "https":
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        context.set_alpn_protocols(["http/1.1"])
        conn = http.client.HTTPSConnection(url.hostname, url.port, context=context, timeout=15)
    elif url.scheme == "http":
        conn = http.client.HTTPConnection(url.hostname, url.port, timeout=15)
    else:
        raise ValueError("expected an http:// or https:// benchmark URL")

    # Include the old discard threshold and larger bodies: the official suite
    # stops at 100 KiB, below the former 256 KiB request_body_buffer_limit.
    sizes = (0, 1, 1024, 10240, 102400, 262144, 262145, 1048576)
    passed = 0
    try:
        conn.connect()
        sock = conn.sock
        for chunked in (False, True):
            for size in sizes:
                payload = os.urandom(size)
                headers = {"Content-Type": "application/octet-stream"}
                if chunked:
                    # Irregular chunks cross the HTTP codec's read boundaries.
                    body = (payload[i:i + 997] for i in range(0, size, 997))
                else:
                    body = payload
                conn.request("POST", "/echo", body=body, headers=headers, encode_chunked=chunked)
                response = conn.getresponse()
                actual = response.read()
                label = f"{'chunked' if chunked else 'Content-Length'} {size}B"
                assert response.status == 200, (label, response.status)
                assert actual == payload, (label, len(actual), len(payload))
                content_types = [v for k, v in response.getheaders() if k.lower() == "content-type"]
                assert content_types == ["application/octet-stream"], (label, content_types)
                lengths = [v for k, v in response.getheaders() if k.lower() == "content-length"]
                assert lengths == [str(size)], (label, lengths)
                assert conn.sock is sock, f"{label}: keep-alive connection closed"
                passed += 1
                print(f"PASS echo {label}, binary bytes and keep-alive")

        # Reusing that connection must leave the parser ready for another route.
        conn.request("GET", "/baseline11?a=19&b=23")
        response = conn.getresponse()
        assert response.status == 200 and response.read() == b"42"
        passed += 1
        print("PASS baseline after repeated echoes")

        conn.request("GET", "/echo")
        response = conn.getresponse()
        assert response.status == 404 and response.read() == b"Not Found"
        passed += 1
        print("PASS echo rejects GET")
    finally:
        conn.close()
    print(f"{passed} passed")


if __name__ == "__main__":
    main()
