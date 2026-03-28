---
title: Implementation Rules
weight: 5
---

These rules exist to keep HttpArena results meaningful and representative of real-world framework performance. They apply to all framework submissions and can be cited during PR reviews.

## Use framework-level APIs

If a framework provides a documented, high-level way to accomplish a task, the benchmark implementation **must** use it.

Don't bypass the framework to hand-roll a faster solution. We're testing frameworks, not testing how clever you are at writing raw socket code.

**Example — route parameter parsing:**

{{< tabs items="Good,Bad" >}}

{{< tab >}}
```python
# Use the framework's built-in parameter binding
@app.get("/baseline")
def baseline(a: int, b: int):
    return {"result": a + b}
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
    return custom_json_bytes(a + b)
```
{{< /tab >}}

{{< /tabs >}}

**Why:** People want to see how their framework performs the way they actually use it — with its routing, serialization, and middleware. If the framework's built-in JSON serializer is slow, that's useful signal. Bypassing it hides the truth.

## Settings must be production-documented

Non-default configuration is allowed **only if the framework's official documentation recommends it for production use**. If you can't link to a docs page that says "use this in production," it doesn't belong in the benchmark.

**Allowed:**
- .NET Server GC ([documented for production workloads](https://learn.microsoft.com/en-us/dotnet/core/runtime-config/garbage-collector))
- JVM `-server` and ergonomics flags (standard production tuning)
- Worker/thread counts matching available CPU cores

**Not allowed:**
- Undocumented flags found by reading framework source code
- Experimental/unstable options that trade safety for speed
- Settings that disable buffering, validation, or error handling

**The test:** If a reviewer asks "where's this setting documented?", you should be able to link the official docs within 30 seconds.

## Use standard libraries and drivers

If the ecosystem has a well-established, production-grade library for a task (database driver, JSON serializer, HTTP client), use it. Don't bring an experimental or hand-rolled alternative just because it's faster in microbenchmarks.

**Example:** If every production app in your language uses `libpq` bindings for Postgres, don't swap in an experimental zero-copy driver that nobody ships to production.

**Exception:** If the framework itself bundles or officially recommends a specific library, that's fine to use.

## Deployment-environment tuning is fine

Adapting to the benchmark hardware is normal and expected:

- Setting worker count to match CPU cores
- Configuring connection pool sizes
- Adjusting memory limits for the container

This is what every production deployment does. The line is: **adapt to the environment, don't exploit it.**

---

These rules boil down to one principle: **benchmark the framework as people actually use it.** If a real team shipping a production API wouldn't do it, it doesn't belong in HttpArena.
