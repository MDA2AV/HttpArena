# Neton

Kotlin Multiplatform compiled to a native executable, on the hyper4k engine
(Tokio + Hyper 1.x, linked in as a Rust static library).

The framework is consumed from Maven Central as a single coordinate:

```kotlin
implementation("com.netonstream:neton:1.0.0-beta6")
```

That one dependency carries core, logging, HTTP, routing and the hyper4k engine,
so this entry builds the way any application would — there is no source checkout
and no composite build.

## Ports

| Port | Protocol |
|---|---|
| 8080 | HTTP/1.1 |
| 8082 | HTTP/2 cleartext (prior knowledge) |

Both listeners serve one route table.

## Running it outside the container

The harness mounts the dataset at `/data/dataset.json`. To run on a developer
machine, point `ARENA_DATASET` somewhere writable:

```bash
./gradlew linkReleaseExecutableMacosArm64
ARENA_DATASET=../../data/dataset.json ./build/bin/macosArm64/releaseExecutable/neton-httparena.kexe
```

## Not subscribed

The TLS profiles (the engine terminates no TLS today) and json-comp, which needs
gzip/br response compression.
