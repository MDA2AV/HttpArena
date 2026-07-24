FROM oven/bun:1.3
WORKDIR /app
COPY package.json ./
RUN bun install --production
COPY server.ts entrypoint.sh ./
RUN chmod +x entrypoint.sh
EXPOSE 8080 8443
CMD ["/app/entrypoint.sh"]
