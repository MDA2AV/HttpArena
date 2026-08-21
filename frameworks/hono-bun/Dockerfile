FROM oven/bun:latest
WORKDIR /app
COPY package.json bun.lock ./
RUN bun install --production --frozen-lockfile
COPY server.ts entrypoint.sh ./
COPY views/ views/
RUN chmod +x entrypoint.sh
EXPOSE 8080 8443
CMD ["/app/entrypoint.sh"]
