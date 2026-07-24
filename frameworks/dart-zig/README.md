# dart-zig

`dart-zig` in HttpArena is split into two images:

- `ghcr.io/kartikey321/dart-zig-runtime`: generic production runtime
- `ghcr.io/kartikey321/dart-zig-builder`: SDK-backed builder image used only at image build time

The benchmark application source lives in this framework directory. The
framework Dockerfile compiles `benchmark_http_server.dart` in a builder stage,
then copies the generated `.dill` into the generic runtime image.

## Default build

```sh
cd frameworks/dart-zig
./build.sh
```

This pulls the published runtime and builder images from GHCR, then builds the
framework image locally.

## Local SDK mode

```sh
cd frameworks/dart-zig
DART_ZIG_USE_LOCAL_BUNDLE=1 \
DART_ZIG_SDK_ROOT=/path/to/sdk \
./build.sh
```

Local mode does two things before building the framework image:

- rebuilds the generic runtime bundle from the local SDK checkout
- builds a local builder image from the same SDK checkout

That keeps the source-of-truth split clean:

- runtime repo owns runtime packaging
- HttpArena owns benchmark app source

## Runtime requirement

`dart-zig` uses Linux `io_uring`. Containers must be started with Docker
seccomp relaxed enough to allow `io_uring`. HttpArena already handles this for
frameworks with `"engine": "io_uring"`.
