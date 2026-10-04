# neton-hyper

Neton 1.0.0-beta22 with Hyper4k (Rust Tokio + Hyper).

The engine is selected explicitly, alongside the framework core, logging, HTTP and routing:

```kotlin
implementation("com.netonstream:neton-http-hyper4k:1.0.0-beta22")
```

Both entries build entirely from Maven Central. Main.kt, compiler, GC and request
admission settings are identical; only Engine.kt and the engine dependency differ.
No local repository, composite build or benchmark-only business fast path is used.

## Ports

| Port | Protocol |
|---|---|
| 8080 | HTTP/1.1 |
| 8082 | HTTP/2 cleartext (prior knowledge) |
| 8081 | HTTP/1.1 TLS |
| 8443 | HTTP/2 TLS (ALPN) |

All listeners serve one route table. TLS starts when the harness mounts certificates.

## Running it outside the container

The harness mounts the dataset at `/data/dataset.json`. To run on a developer
machine, point `ARENA_DATASET` somewhere writable:

```bash
./gradlew linkReleaseExecutableMacosArm64
ARENA_DATASET=../../data/dataset.json ./build/bin/macosArm64/releaseExecutable/neton-httparena.kexe
```

## Comparison

Run neton and neton-hyper baseline separately on the same runner, repeating in
alternating order. Do not run both servers at once. Existing profile subscriptions
are retained, but the first requested comparison is baseline; new-engine
high-load results are not yet known.
