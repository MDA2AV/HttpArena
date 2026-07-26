# The oven/bun x64 images ship the "baseline" (non-AVX2) Bun build for CPU portability. In Bun
# 1.3.x that baseline build has a code-generation bug that miscompiles Seagreen's layout router:
# request dispatch for routes past roughly the fifth entry in a layout 404s even though the
# handlers are registered (/async-db and the deeper /crud routes break). The AVX2 build — the
# flavor `bun.sh/install` selects on an AVX2 CPU, and the one that runs correctly on the host —
# routes them correctly and is faster besides. So we take the Debian (glibc) image for its
# tooling and replace bun with the AVX2 build. glibc, not alpine/musl, because the prebuilt
# AVX2 binary the installer fetches here is glibc-linked.
FROM oven/bun:1
RUN apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/* \
 && curl -fsSL https://bun.sh/install | bash -s "bun-v1.3.14" \
 && cp -f /root/.bun/bin/bun "$(command -v bun)" \
 && rm -rf /root/.bun \
 && echo "bun build flavor: $(bun -e 'throw 0' 2>&1 | grep -o 'Linux x64[^)]*')"
WORKDIR /app

# App deps (reflect-metadata powers the decorator-based webservice routing).
COPY package.json ./
RUN bun install

COPY tsconfig.json ./
COPY src ./src

# Seagreen (the TypeScript GenHTTP port) is consumed by relative import from ./seagreen.
# Cloned at build time from its public repo; bare imports (reflect-metadata) resolve from /app.
RUN git clone --depth 1 https://github.com/dotnet-web-stack/Seagreen.git seagreen

EXPOSE 8080
# Bun runs the TypeScript directly (no build step); main.ts forks one worker per core.
ENTRYPOINT ["bun", "run", "src/main.ts"]
