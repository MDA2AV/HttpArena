# https://elysiajs.com/patterns/deploy.html#deploy-to-production
FROM oven/bun AS build

WORKDIR /app

# Cache packages installation
COPY package.json package.json
COPY bun.lock bun.lock

RUN bun install --production

COPY server.ts .

ENV NODE_ENV=production

RUN bun build \
	--compile \
	--minify \
	--target bun \
	--outfile server \
	server.ts

FROM gcr.io/distroless/base

WORKDIR /app

COPY --from=build /app/server server

ENV NODE_ENV=production

CMD ["./server"]

EXPOSE 3000
