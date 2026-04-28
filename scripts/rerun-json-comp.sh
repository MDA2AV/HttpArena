#!/usr/bin/env bash
# Re-run the json-comp benchmark with --save for every framework subscribed
# to this test. One line per framework, on purpose — just copy/paste.
set -e
cd "$(dirname "$0")/.."

./scripts/benchmark.sh actix json-comp --save
./scripts/benchmark.sh aleph json-comp --save
./scripts/benchmark.sh aspnet-minimal json-comp --save
./scripts/benchmark.sh aspnet-minimal-aot json-comp --save
./scripts/benchmark.sh aspnet-minimal-iouring json-comp --save
./scripts/benchmark.sh aspnet-mvc json-comp --save
./scripts/benchmark.sh bjoern json-comp --save
./scripts/benchmark.sh elysia json-comp --save
./scripts/benchmark.sh fastapi json-comp --save
./scripts/benchmark.sh fastpysgi-asgi json-comp --save
./scripts/benchmark.sh fastpysgi-wsgi json-comp --save
./scripts/benchmark.sh flask json-comp --save
./scripts/benchmark.sh fletch json-comp --save
./scripts/benchmark.sh frankenphp-trueasync json-comp --save
./scripts/benchmark.sh genhttp json-comp --save
./scripts/benchmark.sh genhttp-kestrel json-comp --save
./scripts/benchmark.sh go-fasthttp json-comp --save
./scripts/benchmark.sh h2o-mruby json-comp --save
./scripts/benchmark.sh helidon-production json-comp --save
./scripts/benchmark.sh helidon-tuned json-comp --save
./scripts/benchmark.sh hono-bun json-comp --save
./scripts/benchmark.sh humming-bird json-comp --save
./scripts/benchmark.sh hyperf json-comp --save
./scripts/benchmark.sh ngx-php json-comp --save
./scripts/benchmark.sh php json-comp --save
./scripts/benchmark.sh pyronova json-comp --save
./scripts/benchmark.sh quarkus-jvm json-comp --save
./scripts/benchmark.sh rage json-comp --save
./scripts/benchmark.sh rails json-comp --save
./scripts/benchmark.sh ring-http-exchange json-comp --save
./scripts/benchmark.sh roda json-comp --save
./scripts/benchmark.sh servicestack json-comp --save
./scripts/benchmark.sh sinatra json-comp --save
./scripts/benchmark.sh slimeweb json-comp --save
./scripts/benchmark.sh spring-boot json-comp --save
./scripts/benchmark.sh swoole json-comp --save
./scripts/benchmark.sh uvicorn json-comp --save
