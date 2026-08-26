---
title: Standard
seo_title: "Standard Mode Rules"
description: "Standard mode measures a framework in its default configuration, with no experimental flags, reflecting what developers get out of the box."
weight: 1
---

Standard is the default mode for a framework entry (`mode: standard`). It measures what the framework gives you out of the box, the way developers actually use it in real applications - documented APIs, production-grade settings, and standard libraries.

## Use framework-level APIs

If a framework provides a documented, high-level way to accomplish a task, the benchmark implementation **must** use it. Bypassing the framework to hand-roll a faster solution is not permitted.

{{< tabs items="Good,Bad" >}}

{{< tab >}}
```python
# Use the framework's built-in parameter binding
@app.get("/baseline")
def baseline(a: int, b: int):
    return str(a + b)
```
{{< /tab >}}

{{< tab >}}
```python
# Manually parse query string for speed
@app.get("/baseline")
def baseline(request):
    qs = request.url.query.encode()
    a = fast_parse_int(qs, b"a=")
    b = fast_parse_int(qs, b"b=")
    return custom_serialize(a + b)
```
{{< /tab >}}

{{< /tabs >}}

## Settings must be production-documented

Non-default configuration is allowed **only if the framework's official production deployment guide recommends it**. If there is no official documentation recommending a setting for production use, it does not belong in the benchmark.

**Allowed:**
- GC settings recommended in production deployment guides
- Worker/thread counts matching available CPU cores
- Connection pool sizes for the environment

**Not allowed:**
- Undocumented flags found by reading framework source code
- Experimental or unstable options that trade safety for speed
- Settings that disable buffering, validation, or error handling

## Use standard libraries and drivers

If the ecosystem has a well-established, production-grade library for a task (database driver, JSON serializer), use it. Experimental or hand-rolled alternatives solely for benchmark performance are not permitted.

**Exception:** If the framework itself bundles or officially recommends a specific library, that library is acceptable.

## Static files: the cache is the framework's, not the entry's

For the static file tests an entry may serve file contents out of memory. Caching
is not the thing being excluded - the operating system caches these files anyway,
and after the first read the bytes are in RAM whatever the entry does. Two things
are required instead.

**The cache must be the framework's own.** A documented static file handler, with
whatever caching and invalidation it comes with, is fine - if it passes validation
it counts, and what it does internally is its business. What is not allowed is a
cache assembled in the entry: reading the directory into a map at startup, holding
pre-loaded buffers, mapping the files by hand. Moving that code behind a function
name does not change what a user of the framework actually gets, and what a user
gets is what these numbers are meant to report.

**The cache must follow the disk.** Replace a file and the next response must
carry the new bytes. A cache that is filled once and never revalidated is serving
something the filesystem no longer contains, which is not serving files - it is
replaying them.

Memory-mapping sits on the same footing. It is fine when the framework's static
handler does it and the mapping tracks the file; it is not fine when the entry
maps the directory at startup and serves whatever it captured, because a mapping
keeps pointing at the inode it was opened on and files are normally changed by
being replaced.

This applies to Standard, Tuned and Engine entries alike. Infrastructure entries
(reverse proxies and static-file servers) are exempt from the first requirement as
well: configuring a cache is the job that tier is measuring.

## Static file compression

Compression of static files is optional but recommended for better results. All static file requests include `Accept-Encoding: br;q=1, gzip;q=0.8` - frameworks that compress will naturally benefit from reduced I/O.

**Standard rule:** compression must use the framework's standard middleware or built-in static file handler (e.g., Nginx `gzip on`/`gzip_static on`, ASP.NET response compression middleware, Express `compression()` middleware). No handmade compression code.

Pre-compressed files (`.gz`, `.br`) are available on disk alongside the originals,
and **serving them is allowed for every entry type**. Use the framework's own
feature where it has one (e.g. Nginx `gzip_static`/`brotli_static`, ASP.NET
`MapStaticAssets`, Hono `serveStatic({ precompressed: true })`); where it has
none, select the variant in the entry off `Accept-Encoding`. Those bytes already
exist on disk, so choosing one is a file read, not compression - which is why it
is allowed here while compressing by hand is not. The response must carry the
original file's `Content-Type` and the matching `Content-Encoding`.

This is a deliberate change. The rule used to allow pre-compressed files only
behind a documented API, which made the profile turn on whether a framework
happened to ship that one feature: an entry sending full-size bodies against
entries sending brotli is not doing the same work, and the resulting gap swamped
everything else the profile measures.

What is still out is a **static handler** written for this benchmark. The cache
must be the framework's own and must follow the disk, and nothing may be
compressed at runtime by code in the entry. The line is what the framework gives
you, not what can be written against it: whatever a framework's own static
handler does internally is its business - if it passes validation, it counts.

Tuned entries are free to hand-roll the same thing; the
distinction only binds Standard, where the point is to show what the framework
does out of the box.

## Deployment-environment tuning

Adapting to the benchmark hardware is permitted:
- Setting worker count to match CPU cores
- Configuring connection pool sizes
- Adjusting memory limits for the container

The boundary is: **adapt to the environment, do not exploit it.**
