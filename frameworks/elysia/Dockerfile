# https://elysiajs.com/patterns/deploy.html#deploy-to-production
FROM oven/bun:1.3 AS build

WORKDIR /app

# Cache packages installation
COPY package.json package.json
COPY bun.lock bun.lock

RUN bun install --production

COPY server.ts .
# The fortunes template is imported as text and embedded into the binary, so it
# has to be present when bun build runs.
COPY views ./views

ENV NODE_ENV=production

RUN bun build \
	--compile \
	--minify \
	--target bun \
	--outfile server \
	server.ts

# distroless publishes no version tags, so pin the digest
FROM gcr.io/distroless/base-debian12@sha256:62730825d3cf03571e0a1b8f014748de94d0404500f063593b614c23da38841d

WORKDIR /app

COPY --from=build /app/server server

ENV NODE_ENV=production

CMD ["./server"]

EXPOSE 3000
