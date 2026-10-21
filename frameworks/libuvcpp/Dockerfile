# libuvcpp entry for HttpArena.
#
# The library is built from source here, and it has to be: the published
# `libuvcpp-<version>-linux-x64` release package is built with
# `-DUVCPP_ENABLE_DB_MYSQL=OFF -DUVCPP_ENABLE_DB_PGSQL=OFF`, and the release
# workflow asserts it stays that way with an `ldd` check that fails the build if
# `libpq.so` or `libmysqlclient.so` shows up. That is deliberate -- a release
# package that quietly acquires a database client dependency is a release
# package that stops running on machines that do not have one. So the async-db
# profile cannot be served by the release artifact, and the entry builds the
# library instead, which is also what the other merged C++ entries (cutelyst,
# hical) do.
#
# Everything except libpq is built statically into libuvcpp.so, following
# `.github/workflows/release.yml`'s linux-x64 job, which is the recipe behind
# the artifact users install. The one flag that differs is the Postgres
# backend. The other two backends are left off because this entry does not use
# them: SQLite would otherwise be an extra source download at build time and an
# extra shared object at run time for nothing.
#
# **OpenSSL is built from source.** Not a preference: `SSL_set_quic_tls_cbs`
# is the QUIC API the HTTP/3 leg needs, it landed in OpenSSL 3.5, and Ubuntu
# 24.04's libssl-dev is 3.0.13. Pointing the build at the distro's OpenSSL makes
# CMake's configure-time precheck turn UVCPP_ENABLE_QUIC off with a warning --
# the cache still reads ON, the library just ships without QUIC, and the h3 leg
# dies at run time. So the build is pinned to 3.5.0, sources, static, with
# `-fPIC` (which `no-shared` does not imply, and without which the static
# archive cannot go into a shared object). libpq is linked against the distro's
# OpenSSL, which is a separate copy in a separate object -- see the note on the
# runtime stage.

FROM ubuntu:24.04 AS build

ENV DEBIAN_FRONTEND=noninteractive

# The library source, pinned by commit rather than by tag: a tag can be moved
# and the bytes under it re-uploaded, so a SHA is the only thing that fixes
# which revision gets built. `3fdd6208` was `v1.6.1` -- what the first version
# of this entry built, and what the platform measured as the board's 58 req/s on
# `baseline-h3-64`. The pin has since moved six times: to `2d5fe74`
# (`1.6.20-dev`), then to `6eede33` (`1.6.51-dev`), which was the tip of the
# library's `master` when it was taken and is the revision the platform's fourth
# run measured, then to `8150720` (`1.7.2-dev`), which is the `v1.7.0` tag plus
# one documentation commit and two that change code, then to `02ae418`
# (`1.7.2-dev`), which is four code commits past it and is what the sixth run
# carried, then to `1f6a8fb` (`1.7.2-dev`), which is two code commits and a
# documentation commit past `02ae418` and is what the seventh run carried, and
# now to `0f34937` (`1.7.2-dev`), which is two code commits and four
# documentation commits past `1f6a8fb` and is the tip of the library's `master`
# when it was taken.
# Each move was measured against the previous pin before being taken; the
# criteria for the `6eede33` batch are further down this file, and each commit's
# own criterion is in the library's `CHANGELOG.md`.
#
# The `02ae418` move was the pin the sixth run carried, and like the `8150720`
# move it is a batch whose members carry local deterministic counters rather than
# on-board measurements. The four code commits between the two pins -- the other
# two are documentation -- and what each one's criterion is:
#
#   * `e716010` stops the database path from building a log line when no log
#     callback is installed: `106.16 / 106.15 -> 102.18 / 102.22` allocations
#     per response (A B B A), with `utime + stime` unmoved -- 3.96 allocations
#     is about 0.12 us, under the rig's resolution, so the allocation count is
#     the criterion. `async-db` is Reference-only and contributes nothing to
#     the score; this one is a counter and nothing more.
#   * `3cbfc9a` and `370d6ef` are the QUIC send path. The first lets one
#     datagram carry STREAM frames from several streams (`sendmsg` per request
#     `1.0316 / 1.0360 -> 0.0428 / 0.0561`), the second sizes each send chunk
#     from what that write needs instead of reserving 64 KiB flat (`72 374.8 ->
#     7 507.5` bytes allocated per request, `-89.6%`, peak RSS 91 -> 50 MiB on
#     the local h3 rig, where the flat reserve is the same shape as the 238 MiB
#     the board reports for `baseline-h3-64`). Both are measured on the h3
#     profiles this entry subscribes to, on this machine's rig rather than the
#     board's, and are not offered as predictions.
#   * `02ae418` lets `resp.json()` hand the dumped body to the response instead
#     of copying it: `-1.0000` `memcpy` per request and `-8 397` bytes copied
#     per request -- the body's own length, so it is that copy and not some
#     other one -- with `-0.83%` instructions per request on `/json/50?m=6`.
#     The instruction figure is 0.83% of one handler, smaller than the spread
#     between two board readings; the counters are the criterion.
#
# The `1f6a8fb` move is for the next run and is the shortest batch so far: two
# code commits and a documentation one past `02ae418`, neither of the two
# touching a public header, so this entry needs no code change for it. One of the
# two cannot reach this build at all, and the other is the one that matters.
#
#   * `0aaa415` gives the brotli encoder the ~700 KiB of state it needs per
#     request out of a thread-local arena instead of the heap. brotli has no
#     `BrotliEncoderReset()` -- which is why the deflate arm can carry one kernel
#     across requests and this one cannot -- so the state was created and
#     destroyed on every request, two of its blocks are 256 KiB, and those are
#     above glibc's 128 KiB threshold, so `free` handed them back to the kernel
#     for the next request to fault in again. On the local `br` arm: `72.43 ->
#     0.00` minor faults per request and `508 -> 385` us of CPU per request, with
#     a gzip arm as the negative control (`+0.8%`, no faults either way) and the
#     compressed bytes bit-for-bit the same. The commit's own run of the same
#     effect reads `72.165 -> 0.001` and `515.5 -> 398.5` us; the numbers already
#     in this file above `ARG LIBUVCPP_REF` are this entry's rig on the same
#     request.
#     **This build compiles none of it**: the arena, the encoder
#     call and the frame in between all sit under `#if UVCPP_BROTLI_ENABLE` in
#     `src/web/uvcpp_http_compress.cpp`, and the flag below is
#     `-DUVCPP_ENABLE_BROTLI=OFF`. It comes along because a pin is a commit and
#     not a patch list.
#   * `1f6a8fb` moves the two tables behind the static handler's `LOOP_STAT`
#     cache lookup to a front copy per loop, so that the thread reading them is
#     the thread that wrote them. Before it, every loop read the global tables
#     under one shared lock and the lock was the ceiling: `mutex_lock` per request
#     `2.03 / 2.04 -> 0.03 / 0.02`, time held `3 679 / 4 171 -> 969 / 1 259` ns,
#     time waiting `7 761 / 9 368 -> 183 / 239` ns. At `1 / held` the old lock
#     admits 240 000-270 000 requests a second, which is the order the board's
#     `static-h2` rows sit at (about 235 000) while the same round's
#     `json-tls-4096` spends 63.3 cores at a lower per-request cost -- so the
#     static profiles were short of parallelism, not of work. The local
#     end-to-end moved `+19.6%` (109 997 -> 131 608 req/s, two interleaved
#     rounds, server on 9 cores with the generator pinned to the same machine),
#     which is offered as direction only; the counter and the `1 / held`
#     arithmetic are the criterion. This is the h1/h2 static handler; the h3 leg
#     goes through `uvcpp_static_server` and does not take this path.
#
# The `0f34937` move is for the next run: two code commits and four documentation
# ones past `1f6a8fb`. One of the two does touch a public header -- `239fef0`
# changes the layout of `uvcpp_malloc_block_cache` in `uvcpp_alloc.h`, keeping
# its interface -- but this entry does not include that header (it is reached
# only from `uvcpp_buf.cpp` and `uvcpp_write.cpp`), so no entry change is needed
# and this build gets both sides of it from the same revision. Both commits are
# aimed at regressions the seventh run reported, and both carry a local
# deterministic counter as their criterion.
#
#   * `239fef0` moves the free list of the buffer allocator's own blocks out of
#     the blocks and into per-thread tables. The family serves 1-7 byte blocks --
#     a WebSocket frame header is two bytes and `echo-ws`'s payload is `"hello"`
#     -- and the old scheme wrote the "next block" pointer into the block's first
#     8 bytes, so a block below that size could never go on the list: `put()`
#     freed it in place and `try_take()` could never hit. Four blocks per
#     WebSocket echo message went to `malloc` every time (3 x 5 bytes + 1 x 7
#     bytes, measured at the call site) and none of them was ever reused. On the
#     local rig, message-allocations per message `11.255 -> 6.255` at `PIPE=1`
#     and `3.692 -> 0.567` at `PIPE=16` (A B B A, the same entry binary with only
#     the `.so` swapped, zero spread within a group), and `0.775 -> 0.730` us per
#     message end to end with `PIPE=16` (`-5.8%`, 255 891 -> 267 986 msg/s).
#     `echo-ws-pipeline-4096` is the profile it is aimed at: the seventh run put
#     it at `29 440 675` req/s and `2.31` us of CPU per message, `-6.8%` in rate
#     and `+13.8%` in CPU per request against the sixth run -- the largest
#     single-profile regression in that round -- and its 5-byte payload means
#     none of that cost can be amortised over bytes, so per-message overhead is
#     the whole story.
#   * `2872c20` gives the TCP read buffer a per-thread table of exact-size slots.
#     libuv's `suggested_size` for a TCP stream is 64 KiB flat, so on the
#     `pipeline = 1` profiles, where one read event is one request, every request
#     costs a 64 KiB `malloc`/`free` pair. The pair is cheap by itself; what is
#     not is dragging the large-bin `unlink_chunk` and the fastbin-consolidation
#     scan into the hot path on profiles that already allocate heavily per
#     response. callgrind on this entry, same URL, same binary: `/json/50?m=6`
#     `4 550 109 494 -> 3 796 143 977` instructions (`-16.57%`, with `_int_malloc`
#     12.01% -> 4.86% and `malloc_consolidate` 4.72% -> 0.02%), `/baseline11`
#     `-1.36%`. End to end on the local rig, same entry binary with only the
#     `.so` swapped: `-14.1%` on `/json/50?m=6`, `-8.9%` on the h2c leg, and
#     `baseline11` **neutral** (`11.40 -> 11.60` us, inside the spread).
#
#     (The two ends of this one are worth stating together, because the json
#     profiles are where the `nlohmann` DOM the entry answered with at the time
#     costs the most and this is the only lever left on them: the change cannot
#     touch the serialisation the profile measures, only the allocator traffic
#     underneath it.)
#
# Neither is offered as a predicted board movement. On the h1 profiles the
# `-16.57%` of instructions is one handler's user-mode share of an end-to-end
# cost that those profiles spend mostly elsewhere, and the `-14.1%` and `-5.8%`
# figures are this machine's rig, not the board's.
#
# What this run also carries, and what is *not* in the pin, is the entry side:
# the JSON profiles answer through the framework's standard serializer again
# (see the `/json` note below). The fifth run measured the size of that change
# for us by accident: its tree had the entry on `uvcpp_json_writer` (9257623),
# the revision the maintainer then objected to, and it reported `async-db-1024`
# at `271.85` us of CPU per response against the fourth run's `407.2` -- a fall
# that the doc attributes to that one entry commit and to nothing in the library.
# This entry has the DOM path back, so its `async-db` and `json-*` rows read
# against the sixth run's -- the most recent one that also had it back -- and not
# against the fifth's, whose tree answered through `uvcpp_json_writer`.
#
# The pin this file now names carries the entry side one step further, and its
# `json-*` and `async-db` rows are *not* like-for-like with that run's either:
# both handlers build their bodies with the library's yyjson backend instead of
# the `nlohmann` DOM, so the serializer is a second variable on those rows
# alongside whatever the pin itself moved. That change is argued in full at the
# end of the pin block below, criterion first.
#
# The other entry-side change since the sixth run is on the h3 static leg, and it
# is the same shape of omission the JSON one was. `uvcpp_static_server` is a
# different handler from the `uvcpp_web_app` static code the h1/h2 legs use --
# `uvcpp_web_app` has no QUIC, so `static-h3-64` has to mount this one -- and
# options set on one are not inherited by the other. Its `revalidate` had been
# left on the `POOL` default, so every `static-h3-64` request queued to the libuv
# thread pool to `stat()` there and came back through `after_work`; the h1/h2
# legs have been on `LOOP_STAT` since `7095e92` (`af3b4fc` is where this branch
# got it). One line sets it here. On this machine's h3 rig, one line apart with
# everything else equal: `29 434 -> 38 280` req/s and `216.8 -> 193.3` us per
# request, the two arms' rep ranges not
# overlapping (29 129-30 454 against 33 855-42 360). The library's section 4.8
# ran the same A/B on the same handler with `statx` per request as its control,
# and the control did not move (`2.24` on both arms) -- the mtime and size check
# still happens on every request, only the thread it happens on changed.
#
# The sixth run also turned the framework's brotli encoder on, and this tree turns
# it back off. That is the one change here that is not a like-for-like restoration
# and it is argued in full above `ARG LIBUVCPP_REF`; the short version is that the
# profile's score is quadratic in bytes per response, brotli buys 1.23x on that
# term, and it costs 1.5x of gzip's CPU even after the encoder state is no longer
# re-faulted every request.
#
# The `8150720` move, like the `02ae418` one above and for the same reason, is a
# batch whose criterion is *not* an on-board measurement. Its two commits carry
# a local deterministic counter as their criterion -- `ebeaa20` is `-1.90%`
# user-mode instructions per request on the h1 shape (22,459.6 -> 22,032.4 Ir,
# callgrind, the path normalisation collapsing to one function with a fast path
# for the already-normal form), and `8150720` is `204.78 -> 102.77` `malloc`s per
# response on the async-db shape (the result-set vectors now reserve, which
# `PQntuples`/`PQnfields` let them do exactly). Neither is offered as a predicted
# board movement. The h1 profiles
# are all `pipeline = 1`, so `-1.90%` of user-mode instructions is about `0.35%`
# of the end-to-end time on those profiles, which is smaller than the spread
# between two platform readings of the same profile; and `async-db` is
# Reference-only, contributing nothing to the board's score and showing up only
# in its own `cpu_per_req_us`, which is user plus system time where the change
# is on the user side. So both are accounted for as "the counter certainly went
# down", not as a score. The fifth run has since reported on them, and neither is
# separable in it: that round's rps carried an upward bias of up to 3.2% even on
# the profiles pinned by external factors, where the paragraph above puts
# `ebeaa20`'s `-1.90%` of user-mode instructions at about 0.35% of end-to-end
# time; and `async-db` is one row per round, where that same round's entry-side
# change moved the number by 135 us. The library-side
# criteria and the guards (byte-identical response bodies, the postgres suite
# byte-identical across arms, 127/127 ctest) are in its `CHANGELOG.md`.
#
# `6eede33` is also what the library's `v1.7.0` release carries, in the part
# that decides behaviour: `git diff 6eede33 v1.7.0 -- src/ ':!src/db'` is one
# hunk, the version macros in `src/uvcpp/uvcpp_version.h` -- and nothing else.
# The `src/db/` part of that range is the MySQL/PG backends moving behind a
# `dlopen` seam that is off by default, plus the status enum the seam added; a
# from-source build that does not ask for it is unaffected. Everything else in
# the range is packaging, build system and CI, and only one piece of that
# reaches the ELF build: an `--exclude-libs,ALL` link option that hides symbols
# arriving from static archives and leaves the library's own API exported -- it
# changes the dynamic symbol table, not the code. So the fourth run's numbers
# are `v1.7.0`'s numbers, and the distance from the tag to this pin is small and
# fully accounted for: `git diff --stat v1.7.0 8150720 -- src/ ':!src/db'` is
# the version macros plus four files under `src/webapp/` -- all of them
# `ebeaa20`, the path normalisation -- and `git diff v1.7.0 8150720 -- src/db/`
# is `8150720`, the result-set reservation. The third commit in the range,
# `d9581d9`, is the download table in `README.md`: documentation only. The pin
# stays on the commit rather than moving to the tag because the two behavioural
# commits have no tag -- they are unreleased, and they are the whole reason this
# revision is here.
#
# The tip is a revision whose CI is green on all four platforms -- Linux,
# macOS, MSVC and MinGW-w64 -- which is worth commits that do not otherwise
# matter to this entry. Two of the commits below it fix defects this entry can
# reach:
#
#   * `reply_alive()` no longer dereferences the connection pointer it is handed.
#     It exists to be called *after* a connection may be gone -- it is what the
#     deferred static handler asks before answering from the thread pool, which is
#     the path every `static-*` cache miss takes here -- and it used to read
#     `client->loop_index()` to pick one of the per-loop registration tables.
#     With one loop a fast path skips that read; with `set_loops(n > 1)`, which
#     this entry calls, it is a read of freed memory. ASan caught it on Linux
#     five runs out of five; on Windows the same code is a SEGFAULT, because
#     Windows hands the pages back to the OS.
#   * 413 responses read two bytes past the end of their own status text
#     (`"413 Payload Too Large"` measured as 23 instead of 21). Pre-existing and
#     ASan-only, but a real out-of-bounds read on that branch.
#
# What this pin carries that these profiles depend on, by family:
#
#   static -- serving the on-disk `.br` / `.gz` twin of a file instead of
#     deflating it per request (`precompressed`, on for every static leg this
#     entry mounts: h1-tls, h2 and h3). `uvcpp_static_server` -- which is what
#     the h3 leg uses, there being no `uvcpp_web_app` listener on QUIC -- did not
#     even have a compressed-variant cache, so it ran zlib over the whole file on
#     the loop thread once per request: 933 -> 82,451 rps on the entry's own
#     `data/static` (8 loops, `h2load -p http/1.1 -c 64 -m 2 -n 8000`), while the
#     bytes on the wire fell 24.5%. The `uvcpp_web_app` legs, which already
#     cached the deflated variant, gain +67% and 23.7% fewer bytes. `font/woff`
#     and `font/woff2` also left the MIME table: those containers hold compressed
#     streams, and re-deflating them produced *bigger* output.
#
#   h3 -- `fix(quic): 短包头按「本端 scid_len」解 DCID`. The server decoded a
#     short-header DCID with the *peer's* SCID length, so after the handshake
#     every 1-RTT packet was read as an unknown CID and dropped. On the platform
#     the baseline-h3 run answered 294 responses in its 5 s window -- 4.6 per
#     connection, i.e. one initial PTO per request -- against 9,086,240 rps from
#     the leader on the same box. Locally the same rig goes 63 -> 86,000 req/s
#     with this one line. `fix(quic): 流关闭时把额度还给对端` stops a connection
#     from dying at 100 requests (the server never re-sent MAX_STREAMS), and
#     `feat(quic): QUIC 端点也能扇到多条循环上` gives the endpoint one socket
#     per loop under SO_REUSEPORT. Both are in this pin.
#   h2 -- `fix(webapp): 在途上限不再套在 h2 上`. The default
#     `max_pipelined_requests` of 8 was applied to h2 streams as well as to h1
#     pipelining, so a compliant client was answered `503` + `connection: close`
#     once 8 responses were in flight. Measured locally against the 1.6.0
#     package at the static-h2 shape: 578,096 of 742,441 requests answered 503
#     (78%); after the fix, 49 to 289 of ~163,000 (~0.1%). This is the one that
#     moved the h2 score.
#   h2c and gRPC -- `feat(web): 明文 h2` (prior-knowledge h2c on a cleartext
#     listener, off by default) and the four `feat(grpc)` commits: the
#     length-prefixed frame, the varint field walk, and the `grpc-status`
#     trailer that h2 had to learn to send first. No release has either.
#   static-h3 -- `feat(web): h3 上的稍后应答`. h3 dispatch rejected a deferred
#     response with a 500, which is what kept the static handler off QUIC.
#
# Three more are in the pin because they are fixed, not because these numbers
# depend on them. `fix(http2): WINDOW_UPDATE 不再算进控制帧预算` capped a
# connection at ~1 MiB/s when the peer honours its own flow control, but h2load
# raises its window to 2^30-1 and never sends a WINDOW_UPDATE, so the bucket is
# unreachable from these profiles. `perf(net): 接受连接时默认关 Nagle` is real --
# an h2 reply is written as two segments, and an idle peer's 40 ms delayed ACK
# parks the second -- but it only bites at one request in flight per connection,
# and these profiles run `-m 32` and `-m 100`, where the two arms overlap.
# `perf(web): 压缩不再每请求新建一个 deflate 内核` (+2.4% on json-comp,
# non-overlapping over 5 alternating rounds each way) is folded in as well.
#
# The pin moves past `fix(web): ws 发送队列整批合并` (219b0da), which is the one
# change here that a previous round already measured the absence of. Turning
# TCP_NODELAY on by default removed the incidental Nagle coalescing that had been
# batching the WebSocket echo replies, and `echo-ws-pipeline` fell from
# 10.85M / 12.63M / 10.63M req/s (512 / 4096 / 16384) to
# 4.30M / 3.94M / 3.81M -- while the single-depth `echo-ws` cases did not move
# at all, which is what pointed at the send path rather than the frame path.
# The fix batches a read-dispatch's whole send queue into one `uv_write`; the
# criterion is segments per frame on a 1500-byte veth (1.0000 -> 0.0625) and,
# end to end, 524k-859k frames/s -> 4,111k-5,215k, with a v1.6.1 control arm at
# 0.71 segments/frame and 1,014k frames/s.
#
# The pin then sat on `perf(json): 写出器的键与字符串值改成一次追加` (c8950ae), the
# change this entry's `/json` handler was rewritten onto. **The entry no longer
# uses it.** `uvcpp_json_writer` is an alternative JSON serializer -- the rule
# that lists "Alternative JSON serializers" under Tuned is `tuned.md`, and this
# entry is `mode: standard` -- so these profiles are answered by the framework's
# own JSON backend instead: an `nlohmann::json` DOM through `resp.json()` at the
# pin this paragraph was written at, and a `uvcpp_json_builder` tree written by
# `uvcpp_json_write` since the pin moved to `134f34d`. Both are the framework's
# backend, and the cost of not answering through the streaming writer is on
# `json-comp`, `json-tls` and `/async-db` -- the README's `/json` note is where
# that is recorded. The paragraphs below are kept as the record of why the pin
# moved when it did, not as a description of what this entry does now.
# `uvcpp_json_writer`'s
# `key()` used to append the comma, the opening quote, the escaped body, the
# closing quote and the colon separately -- four or five out-of-line
# `std::string::append` calls per key, three per string value, 4073 of them on a
# 50-item response. They are built in a 256-byte stack buffer and appended once
# now: 4073 -> 1536, byte-identical output. Measured end to end on this entry at
# `/json/50?m=6`, server pinned to 6 single-threaded cores and saturated: 80.4 ->
# 63.2 us of server CPU per request (a repeat run put the pair at 73.8 -> 59.2),
# and 155.0 -> 141.1 us when the client sends `Accept-Encoding: gzip, br`, where
# compressing the 8.4 KB body costs more than writing it. The library-side
# criterion -- the append count, the byte-identity check over 70 `(count, m)`
# pairs and the per-family timings -- is in the library's `CHANGELOG.md`.
#
# The pin sits on `fix(build): brotli 取源码支路把 DLL 路径写进了链接行`
# (6eede33, 1.6.51-dev): the tip of the library's `master` when it was taken, 29
# commits past `c8950ae`, and the first revision whose four CI legs -- Linux,
# macOS, MSVC and MinGW-w64 -- are all green. This is a batch, not one named
# change, so the evidence is per-profile rather than per-commit; each change's
# own criterion is in the library's `CHANGELOG.md`, and what follows is what
# this entry's profiles do with them.
#
# The change that decides the move is the one `baseline-h3-64` was measuring the
# absence of. At `v1.6.1` -- the revision the merged entry pins, and the one that
# produced the board's 58 req/s -- the server decodes the short-header DCID from
# the *peer's* SCID length, so every 1-RTT packet after the handshake is dropped.
# `745608c` fixes it and is not in `v1.6.1`. Both arms below are this repository's
# entry, both libraries are built with the platform's own flag set
# (`BUILD_SHARED_LIBS=OFF`, `CMAKE_POSITION_INDEPENDENT_CODE=ON`, WEB / WEBAPP /
# ZLIB / OPENSSL / NGHTTP2 / QUIC / HTTP3 / DB / DB_PGSQL on, everything else off)
# and both are driven by the platform's own command lines, three runs each,
# median:
#
#   profile (platform command line)        merged @ v1.6.1    this branch @ 6eede33
#   baseline-h2   -c 64 -m 100                   618,420 rps             724,800 rps
#   baseline-h3   -c 64 -m 64, --alpn-list=h3         45 rps             200,999 rps
#   static-h2     -c 64 -m 32                     13,027 rps              28,937 rps
#   static-h3     -c 64 -m 64, --alpn-list=h3         33 rps              14,223 rps
#
# Every 6eede33 row above is 0 3xx / 0 4xx / 0 5xx across all three runs. The two
# h3 rows are not like-for-like and are not offered as such: the merged entry has
# no HTTP/3 static leg at all -- it mounts `serve_static` on the h1-TLS and h2
# listeners only -- so its 33 req/s is 404s, and adding `uvcpp_static_server` on
# the QUIC listener is what makes `static-h3` a profile this entry can even
# subscribe to. The h2 rows are the same shape on both sides, so the 1.17x and
# 2.22x there are the batch's own effect on those two profiles.
#
# What else is in the 29 commits, by the criterion each one carries in the
# `CHANGELOG.md` (these are library-side numbers; the entry-level effect is the
# h2 row above): the static hot path's `realpath` calls per request 2.734 -> 0.001
# and its lock acquisitions 9 -> 1, `slot_here()`'s 18.4 -> 0; the revalidation
# `stat` can move off the thread pool onto the loop thread
# (`uvcpp_web_revalidate`, default unchanged); the h2 outbound batch is capped at
# 64 KiB, which is where `static-h2`'s multi-gigabyte residency came from; the
# static whole-read quota is returned on the worker instead of the loop, which is
# what the batch of `503`s was; the h3 static leg gets `cache_tag` and a bounded
# LRU and stops copying the whole body on a hit; an h1 pipeline's final
# `Connection: close` no longer takes the earlier responses with it; and the h2
# outbound body is held by reference rather than copied per response. Two optional
# modules arrive in the same range and both default to OFF -- a yyjson backend and
# a brotli encoder. Of the two, the yyjson one is now on in the flag set above,
# and the next paragraph is why; brotli stays off two paragraphs further down.
#
# `UVCPP_ENABLE_YYJSON`. The pin moves to `134f34d`, the tip of the library's
# `master` when it was taken. Three things are in that range. `a063645` gives the
# JSON backend a construction side and yyjson's own serializer, and that is what
# `/json` and `/async-db` answer through now -- it is the reason for this move.
# `638512b` takes three copies off the h1 dynamic hot path (`-11.03%` user-mode
# instructions per request on the library's own callgrind rig, which the commit
# sizes at `-3` to `-4%` end to end and does not claim as a board movement
# either); it is a library-side change and it is not a like-for-like factor on
# this entry's h1 rows against the previous run's. The library's fourth database
# backend (ODBC, PR #36) lands in the same range with its CI and packaging; it is
# off in the flag set below. Four CI legs on `134f34d` -- Linux, macOS, MSVC and
# MinGW-w64 -- are green.
#
# What changed, in one sentence: the handlers no longer build an `nlohmann::json` DOM
# per request. They build a `uvcpp_json_builder` tree and hand it to
# `uvcpp_json_write`, which is yyjson's own serializer (`yyjson_mut_val_write_buf`)
# -- and yyjson is a production-grade library the framework itself bundles, which
# is the standard rule's own exception
# ("If the framework itself bundles or officially recommends a specific library, that
# library is acceptable", `implementation-rules/frameworks/standard.md`). It is also
# the backend decision the shipped packages already make: all six release legs pass
# `-DUVCPP_ENABLE_YYJSON=ON` in their package builds, so this is the released
# library's own configuration rather than an entry-only one.
#
# The criterion is byte-identity, and it is met. Same library, two `main.cc`, 17 URLs
# -- `/json/0` through `/json/50` with and without `m`, `count` past the end of the
# dataset, one negative `count`, one `m` of a million, and five `/async-db` ranges
# against the seeded Postgres: every body `cmp`-equal, every status line identical,
# every `Content-Type` identical. The key order the DOM path got for free from
# `std::map` is spelled out in the builder -- insertion order is what a builder keeps
# -- and the nested `rating` object is rebuilt key by key, because the data file lists
# it `score, count` while the response has always answered `count, score`. Getting
# that wrong would have been a silently different body, not a crash.
#
# Measured on the local rig, the same library with only `main.cc` swapped, arms
# alternating over four rounds, the client at the shape these profiles actually use
# (`pipeline = 1`, 1024 connections -- `scripts/lib/profiles.sh` has `json-comp`,
# `json-tls` and `async-db` at pipeline 1, and depth past the library's documented
# per-connection cap answers `503`). `/json/50?m=6`: 228.60 -> 125.31 us of server CPU
# per request and 60,350 -> 89,605 req/s, the arms' four-round ranges not overlapping
# (228.60-303.57 against 125.31-156.23 us). `/async-db` at `min=1&max=500&limit=20`:
# 258.62 -> 158.95 us and 30,794 -> 41,120 req/s (258.62-319.94 against 158.95-194.29).
# Both arms answered zero non-2xx. Both arms also run the same library, so `638512b`
# and the ODBC batch are held constant and are in neither column. The dataset is
# additionally parsed once at startup by `uvcpp_json_parse` instead of being held as
# an `nlohmann::json`; that parse happens before the first request is accepted, so it
# is in neither figure.
#
# Why brotli is off, given that `json-compressed` is the one profile in this suite
# whose request asks for it (`Accept-Encoding: gzip, br`, byte for byte in
# `requests/json-gzip-*.raw`; equal `q` resolves to `br` by the rank rule in
# `web/uvcpp_http_compress.cpp`). It was on for exactly one run, the sixth, and that
# run measured it. Against the fifth run, whose tree built this flag out and answered
# with gzip, `json-comp-4096` went 335 926 -> 50 389 rps (-85.0%) with `CPU/req`
# 186.4 -> 1 238.2 us, and `json-comp-16384` 330 411 -> 59 118 with 196.9 -> 1 036.5
# us. Both runs saturate the same 62 cores (62.4 / 61.3), so that is cost per request
# and not a core given up. Three other `json-*` profiles carry the same batch's
# standard serializer and pay 58-66 us each for it (`json-h2c-1024` 38.5 -> 96.6,
# `json-h2c-4096` 39.5 -> 98.4, `json-tls-4096` 87.4 -> 153.8), which leaves about
# 990 us of the json-comp increase on the encoder.
#
# The ~+31.5 us that was predicted for that encoder was measured single-threaded, and
# the cost is a function of concurrency too. Same entry, same request, server pinned
# to 8 cores, only `Accept-Encoding` swapped: gzip 257 us, `br` 508 us with 72.43
# minor faults per request -- the encoder's ~700 KB of state being handed back to the
# kernel between requests and re-faulted in. Removing that churn is a real fix and
# the library's `master` now carries it (`0aaa415`'s thread-local arena -- with
# brotli off it is a no-op for this entry, which is why the pin now carrying it
# changes nothing in these rows; raising
# `MALLOC_MMAP_THRESHOLD_` and `MALLOC_TRIM_THRESHOLD_` does the same thing from
# outside, which is what made the cause unambiguous): faults 72.43 -> 0.00, `br`
# 508 -> 385 us. 385 against gzip's 257 is still 1.5x, and that is the ratio at its
# kindest -- 1.94x before the fix. The gap this machine cannot reproduce, the board's
# 990 us against the 251 us it measures here, is in the direction that makes `br`
# worse, not better.
#
# 1.5x is more than the profile pays for. Its score is `rps * (minBpr/bpr)^2`, so `br`
# buys `(1429.2/1288.4)^2 = 1.23` on the byte term and has to cost less than 1.23x of
# gzip to be worth having. It costs 1.5x with the known fix already applied.
#
# The other half of the earlier case -- that the profiles merely passing `br` through
# (gateway-64, gateway-h3, production-stack) are not CPU-bound and so collect the same
# ~11% smaller bodies for free -- protects a quantity that is not scored anywhere.
# `effectiveRps` and `minBpr` occur in exactly one file of this repository's profile
# documentation, `h1/json-compressed/implementation.md`; no other profile is scored on
# response bytes. `json-tls`, `json-h2c`, `async-db` and the h1 baselines send no
# `Accept-Encoding` at all. The static legs serve the `.br` twins `data/static` already
# ships, and that selection is runtime in `http_pick_precompressed_variants()`,
# unaffected by this flag in either direction. And no client here asks for `br`
# without also accepting gzip: `json-comp` sends `gzip, br`, the h2 and h3 load
# generators send `br;q=1, gzip;q=0.8`, and `scripts/validate.sh` reads "Must return
# Content-Encoding: gzip or br when Accept-Encoding is sent". So gzip is a valid
# negotiated answer on every profile, and no request comes back uncompressed.
#
# The profile's own guide settles it rather than merely permitting it. Its
# `standard=` rule asks for "the framework standard JSON serialization and the
# framework or engine's built-in response compression (middleware, filter, or
# equivalent)"; `tuned=` only adds "as long as the output is valid gzip or brotli";
# and the worked example under its "Expected response" heading answers a request
# that carried `Accept-Encoding: gzip, br` with `Content-Encoding: gzip`. The page's
# title and its SEO title both name brotli, but no rule in it prefers one encoding,
# and this entry is `mode: standard` -- so the framework's own middleware, answering
# gzip, is what the guide asks for.
ARG LIBUVCPP_REPO=https://github.com/Antruly/libuvcpp.git
ARG LIBUVCPP_REF=134f34db3b7eba08290504480fa89062fde5a3b5

ARG OPENSSL_VERSION=3.5.0

# `make` is here for OpenSSL, and only for OpenSSL: `./Configure` writes a
# Makefile whatever generator the project uses, so the `make -j"$(nproc)"` two
# steps down needs it, and `ninja-build` next to it does not stand in for it.
# The release workflow's linux legs do not list `make` and do not need to --
# they run on a GitHub-hosted image, which has build-essential already. A bare
# ubuntu:24.04 does not: `g++` pulls in gcc, binutils and libc6-dev but not
# `make`. Measured, not assumed -- the first run of this entry died at
# `[build 3/8]` with `/bin/sh: 1: make: not found` (exit 127).
#
# `zlib1g-dev` was listed here at the `v1.6.1` pin and has been dropped, because
# the install rules ship the headers themselves as of 1.6.3. The reason it was
# listed: the library fetches zlib and links it in statically
# (`-DCMAKE_DISABLE_FIND_PACKAGE_ZLIB=ON` below), so nothing on the system path
# provides `zlib.h` -- yet the installed public header `web/uvcpp_ws_parser.h`
# does `#include <zlib.h>` under `#if UVCPP_ZLIB_ENABLE`, and the generated
# `uvcpp_config.h` defines that to 1 (with an `#error` against defining it to 0
# yourself), so a consumer compiling against `/opt/uvcpp/include` cannot opt out
# of it. Before the fix, `[build 8/8]` died with
# `/opt/uvcpp/include/web/uvcpp_ws_parser.h:31:10: fatal error: zlib.h: No such
# file or directory`. Confirmed against this pin rather than assumed: `g++ -H`
# resolves `<zlib.h>` to `<prefix>/include/zlib.h`, and it keeps resolving there
# with the package gone, since `-I` is searched before the system directories.
# `libbrotli-dev` was listed here while `-DUVCPP_ENABLE_BROTLI` was ON (it is the
# package that keeps the encoder off the FetchContent branch, which would otherwise
# clone brotli at build time) and is dropped with the flag: the build out in the flag
# set below means CMake never looks for it, and the library's `<brotli/encode.h>` is
# inside one `.cpp`, so nothing in the installed tree reaches for the package either.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates cmake curl g++ git libpq-dev make ninja-build \
 && rm -rf /var/lib/apt/lists/*

# OpenSSL with the QUIC API: static, PIC, no test suite.
#
# `nm` on the archive is the assertion that matters. Without it a wrong
# OpenSSL silently produces a QUIC-less library (see the header), and the
# failure surfaces much later as an h3 listener that never comes up. Checking
# the library itself, not the headers, is the point: a header can declare a
# symbol the archive never defines. ` [TW]$` requires a definition, and the
# members of an archive carry no `@@OPENSSL_x.y.z` suffix, so the anchor is
# correct here.
RUN set -eux; \
    mkdir -p /opt/openssl-src; \
    curl -fsSL --retry 3 --retry-delay 5 -o /tmp/openssl.tar.gz \
        "https://codeload.github.com/openssl/openssl/tar.gz/refs/tags/openssl-${OPENSSL_VERSION}"; \
    tar xzf /tmp/openssl.tar.gz -C /opt/openssl-src --strip-components=1; \
    cd /opt/openssl-src; \
    ./Configure --prefix=/opt/openssl --libdir=lib no-shared no-tests -fPIC; \
    make -j"$(nproc)"; \
    make install_sw; \
    /opt/openssl/bin/openssl version; \
    nm --defined-only /opt/openssl/lib/libssl.a \
        | grep -qE ' [TW] SSL_set_quic_tls_cbs$'; \
    rm -rf /tmp/openssl.tar.gz /opt/openssl-src

WORKDIR /src
RUN git init . \
 && git remote add origin "${LIBUVCPP_REPO}" \
 && git fetch --depth 1 origin "${LIBUVCPP_REF}" \
 && git checkout FETCH_HEAD

# `BUILD_SHARED_LIBS=OFF` makes every fetched dependency (libuv, llhttp, zlib,
# yyjson, nghttp2, ngtcp2, nghttp3) a static library, and
# `OPENSSL_USE_STATIC_LIBS=ON` does the same for OpenSSL, so libpq is the only
# shared object the result needs beyond libc and libstdc++.
# `CMAKE_POSITION_INDEPENDENT_CODE=ON` is
# required, not defensive: BUILD_SHARED_LIBS=OFF also flips CMake's PIC default
# to OFF, and a non-PIC libuv/llhttp cannot be linked into libuvcpp.so.
#
# `UVCPP_ENABLE_YYJSON=ON` is the JSON backend the `/json` and `/async-db`
# handlers answer through, and it is the flag the six release legs already pass
# in their package builds (`release.yml`), so what this entry builds is the
# released configuration and not an entry-only one. It fetches yyjson 0.13.0
# over FetchContent exactly like the other five dependencies and compiles its
# single `.c` into this same `libuvcpp.so` -- nothing extra is installed and
# nothing else in the image changes. The paragraph at the pin note above is the
# argument; the short version is that the profile's standard rule admits a
# library the framework itself bundles, and this one it bundles.
#
# `UVCPP_ENABLE_DB_ODBC=OFF` is stated rather than left to the default, and the
# default is why: the pin below carries the library's fourth database backend
# (`1607dff`), whose option defaults ON and needs `sql.h` plus a driver manager.
# This image installs neither, so CMake would force the backend off itself and
# say so in a configure-time warning -- the same end state, reached by a warning
# instead of a flag. The entry needs Postgres and nothing else, which is what the
# two `OFF`s next to it already say.
#
# websocket, static files, h2 and h3 all come from these same flags -- there is
# no second build for the TLS legs.
RUN cmake -S . -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/opt/uvcpp \
        -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
        -DUVCPP_BUILD_LIBUV_FROM_SOURCE=ON \
        -DUVCPP_BUILD_SHARED=ON \
        -DUVCPP_BUILD_STATIC=OFF \
        -DUVCPP_BUILD_TESTS=OFF \
        -DUVCPP_BUILD_FUNCTIONAL=OFF \
        -DUVCPP_BUILD_EXAMPLES=OFF \
        -DUVCPP_BUILD_BENCH=OFF \
        -DUVCPP_BUILD_WEB=ON \
        -DUVCPP_BUILD_WEBAPP=ON \
        -DUVCPP_ENABLE_ZLIB=ON \
        -DUVCPP_ENABLE_YYJSON=ON \
        -DUVCPP_ENABLE_BROTLI=OFF \
        -DUVCPP_ENABLE_OPENSSL=ON \
        -DUVCPP_ENABLE_NGHTTP2=ON \
        -DUVCPP_ENABLE_QUIC=ON \
        -DUVCPP_ENABLE_HTTP3=ON \
        -DUVCPP_ENABLE_DB=ON \
        -DUVCPP_ENABLE_DB_PGSQL=ON \
        -DUVCPP_ENABLE_DB_MYSQL=OFF \
        -DUVCPP_ENABLE_DB_SQLITE=OFF \
        -DUVCPP_ENABLE_DB_ODBC=OFF \
        -DUVCPP_ENABLE_CAPI=OFF \
        -DUVCPP_ENABLE_WSDL=OFF \
        -DOPENSSL_USE_STATIC_LIBS=ON \
        -DOPENSSL_ROOT_DIR=/opt/openssl \
        -DCMAKE_DISABLE_FIND_PACKAGE_ZLIB=ON \
 && cmake --build build --parallel "$(nproc)" \
 && cmake --install build

# The entry itself. `-pthread` because libuv is inside the library and the
# static OpenSSL inside it uses thread-local storage.
COPY main.cc .
RUN g++ -std=c++11 -O2 -DNDEBUG -o /server main.cc \
        -I/opt/uvcpp/include \
        -L/opt/uvcpp/lib \
        -luvcpp -lpq \
        -Wl,-rpath,/opt/uvcpp/lib \
        -pthread

FROM ubuntu:24.04

# libstdc++ for the entry's own objects, and libpq5 for the one shared library the
# build above could not absorb. `libbrotli1` was the other one while
# `-DUVCPP_ENABLE_BROTLI` was ON: unlike zlib and libuv, which the project fetches
# and links statically, that flag takes the system copy, so `libuvcpp.so` carried
# `libbrotlienc.so.1` and `libbrotlidec.so.1` in its `DT_NEEDED` and the server would
# not start without them (on noble both are files of that one package -- the name is
# not `libbrotlienc1`, which exists on Debian but not here). With the flag off the
# library carries neither, and this stage does not need them.
#
# apt pulls in libpq's transitive closure
# (libgssapi, libldap, libgnutls, libssl3t64, ...) on its own -- that OpenSSL
# 3.0 is libpq's, and it is a different copy from the 3.5 the library carries
# statically. Both live in the process; only libuvcpp.so's copy serves the h2
# and h3 listeners.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        libpq5 libstdc++6 \
 && rm -rf /var/lib/apt/lists/*

COPY --from=build /opt/uvcpp/lib/libuvcpp.so /opt/uvcpp/lib/libuvcpp.so
COPY --from=build /server /server

# 8080 HTTP/1.1 + h2c, 8081 HTTPS/1.1, 8082 h2c, 8443 TCP+TLS for h2 and 8443
# UDP for h3. The benchmark reaches these through --network host, where EXPOSE is
# documentation; the validation harness publishes them with -p on a bridge
# network, and that is where the two 8443 entries stop being one line.
EXPOSE 8080 8081 8082 8443 8443/udp

CMD ["/server"]
