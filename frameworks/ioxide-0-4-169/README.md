# ioxide-0.4.169

The `ioxide` entry exactly as it stood at `cc794d06`, on ioxide **0.4.169** —
the last version measured at 4.1M req/s on baseline. It exists only to separate
a library regression from a change in the machine.

**Disabled on purpose.** It never sends FIN on `Connection: close`, which is why
the live entry was disabled at #1289 and fixed in 0.7.210, so it does not pass
`validate.sh`. `benchmark.sh` does not check `enabled`, and the workflow's
`enabled` filter only applies to `framework=all`, so it can still be benchmarked
by name.

## The measurement it is meant to settle

| | baseline-4096 | CPU | %CPU per krps |
|---|---|---|---|
| 0.4.169 (2026-08-09) | 4,108,420 | 6401.5% | 1.558 |
| 0.7.211 (2026-08-28) | 3,896,541 | 5983.6% | 1.535 |

Throughput fell ~5% while CPU fell ~6.5%, so cost per request did not rise — the
box is doing less total work rather than more work per request. No measurement
exists for 0.7.210 on its own; the drop is attributed across the version bump
and the entry's own changes together.

Run this and the live entry back to back in the same session. Same numbers as
today's ioxide means the machine moved; ~4.1M again means it is the library.

## The runtime was the uncontrolled variable

The first version of this entry pinned ioxide and left the base image on the
floating `11.0-preview` tag — so both arms of the comparison ran the same
runtime and the old entry regressed too, which proves nothing about the library.

That tag moved:

| tag | published | resolves to |
|---|---|---|
| `11.0.0-preview.6` | 2026-07-28 | 11.0.0-preview.6.26359.118 |
| `11.0.0-preview.7` | 2026-08-28 | 11.0.0-preview.7.26381.103 |

The 4.1M baseline was measured on **2026-08-09**, when `11.0-preview` was
preview.6. The 3.9M was measured on **2026-08-28**, the day preview.7 shipped.

So this entry pins both images. `DOTNET_SDK_TAG` and `DOTNET_RUNTIME_TAG` are
separate build args because the two repositories version differently:
`11.0.100-preview.N` for the SDK, `11.0.0-preview.N` for the runtime.

Run it as-is (preview.6) against the same ioxide on preview.7 — override with
`--build-arg DOTNET_SDK_TAG=11.0.100-preview.7 --build-arg
DOTNET_RUNTIME_TAG=11.0.0-preview.7` — and the runtime is the only thing that
differs.

## Not the FIN fix

The baseline workload never sends `Connection: close` — zero occurrences in
`get.raw`, `post_cl.raw` and `post_chunked.raw` — and the `shutdown(fd, SHUT_WR)`
added in 0.7.210 runs at connection teardown, outside the request loop. With
`req_per_conn=0` it fires once per connection, not per request.

The baseline profile spec (`1|0|0-31,64-95|512,4096|`) is byte-identical between
the two dates, and `gcannon.sh`, `system.sh` and `framework.sh` are unchanged in
that window, so the load side is not the variable either.

## Restored verbatim

Every source file is `git show cc794d06:frameworks/ioxide/<file>`. Two
deliberate deviations:

- `nuget.config` keeps only nuget.org. The original also listed a local feed at
  a developer path for then-unpublished packages; 0.4.169 is published, and the
  path does not exist on the runner.
- `tests` is trimmed to `baseline` and `json`. The original also listed `static`,
  `crud`, `api-4` and `api-16`, which are no longer profiles (#1331, #1374).
