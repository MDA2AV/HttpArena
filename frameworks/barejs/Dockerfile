FROM oven/bun:1.4.4

WORKDIR /app
COPY package.json .
RUN bun install --production
COPY server.ts ./
COPY views ./views

ENV NODE_ENV=production
EXPOSE 8080 8081 8082 8443 8443/udp
CMD ["bun", "server.ts"]
