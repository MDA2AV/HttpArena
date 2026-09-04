# 1.4.1 is the floor: `http2: true` shipped there (oven-sh/bun#40137) and 1.4.0
# ignores the flag rather than rejecting it, so :8082 and :8443 answer HTTP/1.1.
ARG BUN_VERSION=1.4.1
FROM oven/bun:${BUN_VERSION}
WORKDIR /app
COPY server.ts entrypoint.sh ./
RUN chmod +x entrypoint.sh
EXPOSE 8080 8081 8082 8443 8443/udp
CMD ["./entrypoint.sh"]
