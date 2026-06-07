// ReSharper disable always CheckNamespace
// ReSharper disable always SuggestVarOrType_BuiltInTypes
// (var is avoided intentionally in this project so that concrete types are visible at call sites.)
// ReSharper disable always StackAllocInsideLoop
// ReSharper disable always ClassCannotBeInstantiated
#pragma warning disable CA2014


namespace Shrike;

/// <summary>
/// ShrikeEngine — a minimal, high-performance HTTP engine core built around
/// Linux <c>epoll</c> and <c>eventfd</c>, written in C# with unsafe paths and pooling to
/// minimize allocations and syscalls. This class owns process-wide configuration, socket
/// initialization, worker creation, the accept loop, and the request/response I/O pipeline.
/// </summary>
/// <remarks>
/// <para><b>Design goals</b></para>
/// <list type="bullet">
///   <item><description>Throughput first: epoll-driven, non-blocking I/O; batched accept and send.</description></item>
///   <item><description>Predictable latency: avoid cross-thread contention; per-worker ownership of fds.</description></item>
///   <item><description>Low GC pressure: slabbed receive/write buffers; pooled <c>Connection</c> instances.</description></item>
///   <item><description>Simple mental model: one acceptor + N workers; explicit state transitions.</description></item>
/// </list>
///
/// <para><b>High-level architecture</b></para>
/// <list type="number">
///   <item>
///     <description>
///       <b>Acceptor thread</b> (runs on the caller thread):
///       <list type="bullet">
///         <item><description>Owns the listening socket (<c>_listenFd</c>), set to O_NONBLOCK.</description></item>
///         <item><description>Has a dedicated epoll fd and waits for <c>EPOLLIN</c> on the listen socket.</description></item>
///         <item><description>On readiness, drains <c>accept4()</c> in a loop until <c>EAGAIN</c>.</description></item>
///         <item><description>For each accepted <c>cfd</c>, selects the least-busy worker (by <c>Worker.Current</c>), enqueues the fd into the worker’s inbox, and signals the worker via <c>eventfd</c>.</description></item>
///       </list>
///     </description>
///   </item>
///   <item>
///     <description>
///       <b>Workers</b> (<c>_nWorkers</c> threads):
///       <list type="bullet">
///         <item><description>Each worker owns an epoll instance, an eventfd (<c>NotifyEfd</c>), and an fd→<c>Connection</c> map.</description></item>
///         <item><description>On eventfd wakeup, they dequeue new client fds and register them for <c>EPOLLIN|EPOLLRDHUP|EPOLLERR|EPOLLHUP</c>.</description></item>
///         <item><description><c>EPOLLIN</c>: recv into the per-connection receive slab; parse complete requests; write responses into the write slab; try to flush immediately.</description></item>
///         <item><description><c>EPOLLOUT</c>: continue flushing partial responses; on drain, re-arm <c>EPOLLIN</c>.</description></item>
///         <item><description>On error/hangup, the worker closes the fd and returns the <c>Connection</c> to the pool.</description></item>
///       </list>
///     </description>
///   </item>
/// </list>
///
/// <para><b>Core data structures</b></para>
/// <list type="bullet">
///   <item><description><c>Connection</c>: pooled object containing receive/write slabs (unsafe pointers), head/tail indices, and lightweight per-request state (e.g., hashed route).</description></item>
///   <item><description><c>ObjectPool&lt;Connection&gt;</c>: reduces allocation churn under load; return path can reset buffers.</description></item>
///   <item><description>Header parsing helpers: naive but vectorized <c>IndexOf</c>(CRLF/CRLFCRLF), and a route hash via <c>Fnv1a32</c>.</description></item>
/// </list>
///
/// <para><b>I/O flow (hot path)</b></para>
/// <list type="number">
///   <item><description>recv → accumulate bytes in <c>ReceiveBuffer</c> [Head..Tail).</description></item>
///   <item><description>Find <c>\r\n\r\n</c>; on full header → extract target → <c>_sRequestHandler(connection)</c> writes response into <c>WriteBuffer</c>.</description></item>
///   <item><description>send(MSG_NOSIGNAL) until EAGAIN or fully flushed; if partial → arm <c>EPOLLOUT</c>; if drained → arm <c>EPOLLIN</c>.</description></item>
/// </list>
///
/// <para><b>Threading &amp; synchronization</b></para>
/// <list type="bullet">
///   <item><description>Acceptor is single-threaded; workers are OS threads with configurable stack size (defaults 1 MiB).</description></item>
///   <item><description>Work distribution via lock-free queue (worker inbox) + eventfd wakeup (8-byte increments).</description></item>
///   <item><description><c>Worker.Current</c> is adjusted with <c>Interlocked</c>; least-busy selection uses <c>Volatile.Read</c> inside a simple O(N) scan.</description></item>
/// </list>
///
/// <para><b>Configuration knobs (set via <c>ShrikeBuilder</c>)</b></para>
/// <list type="bullet">
///   <item><description><c>_port</c>, <c>_backlog</c>: listener endpoint and queue size.</description></item>
///   <item><description><c>_maxNumberConnectionsPerWorker</c>: map capacity &amp; planning per worker.</description></item>
///   <item><description><c>_inSlabSize</c>/<c>_outSlabSize</c>: receive/write slab sizes (defaults 16 KiB).</description></item>
///   <item><description><c>_maxEventsPerWake</c>: epoll batch size per wait.</description></item>
///   <item><description><c>_maxStackSizePerThread</c>: worker thread stack (useful for <c>stackalloc</c> heavy code paths).</description></item>
///   <item><description><c>_calculateNumberWorkers</c>: custom worker count heuristic; defaults to <c>ProcessorCount / 2</c>.</description></item>
///   <item><description><c>_sRequestHandler</c>: application callback that writes to <c>WriteBuffer</c>.</description></item>
/// </list>
///
/// <para><b>Socket &amp; epoll setup</b></para>
/// <list type="bullet">
///   <item><description>Listener: <c>socket(AF_INET, SOCK_STREAM|CLOEXEC, IPPROTO_TCP)</c>, <c>SO_REUSEADDR</c>, <c>O_NONBLOCK</c>, <c>bind(0.0.0.0:port)</c>, <c>listen(backlog)</c>.</description></item>
///   <item><description>Acceptor epoll: monitor <c>EPOLLIN|EPOLLERR|EPOLLHUP</c> on the listen fd.</description></item>
///   <item><description>Accepted sockets: <c>TCP_NODELAY</c>, <c>SO_LINGER</c> off, <c>O_NONBLOCK</c> (via <c>accept4</c> flags).</description></item>
/// </list>
///
/// <para><b>Error handling</b></para>
/// <list type="bullet">
///   <item><description>EINTR/EAGAIN/EWOULDBLOCK are treated as transient.</description></item>
///   <item><description>ECONNRESET/ECONNABORTED/EPIPE close the connection.</description></item>
///   <item><description>Unexpected errors during recv/send/ctl cause a quiet close; the worker load counter is decremented.</description></item>
/// </list>
///
/// <para><b>Performance notes</b></para>
/// <list type="bullet">
///   <item><description>Batching: accept loop drains in one epoll tick; send loop attempts to drain buffer before arming <c>EPOLLOUT</c>.</description></item>
///   <item><description>Pooling: <c>Connection</c> reuse avoids per-request allocations; slabs are fixed-size for cache locality.</description></item>
///   <item><description>Vectorized searches: <c>Span&lt;&gt;.IndexOf</c> on constants like <c>CRLFCRLF</c> leverages SIMD on modern runtimes.</description></item>
/// </list>
///
/// <para><b>Safety &amp; invariants</b></para>
/// <list type="bullet">
///   <item><description>All fds registered in a worker’s epoll must be serviced only by that worker.</description></item>
///   <item><description>For <c>ReadOnlySpan</c> over <c>byte*</c>, callers guarantee the [Head..Tail) window is valid and pinned for the call duration.</description></item>
///   <item><description><c>WriteBuffer</c> and <c>ReceiveBuffer</c> head/tail invariants are maintained by <c>Connection</c> methods and parsing routines.</description></item>
/// </list>
///
/// <para><b>Extensibility</b></para>
/// <list type="bullet">
///   <item><description>Custom routing/dispatch: swap <c>_sRequestHandler</c>; keep response writes contiguous for fewer syscalls.</description></item>
///   <item><description>Back-pressure: introduce per-fd send windowing or global egress caps if needed.</description></item>
///   <item><description>HTTP parsing: current header scan is naive; can be upgraded with SIMD or a finite-state parser.</description></item>
/// </list>
///
/// <para><b>Limitations / TODO</b></para>
/// <list type="bullet">
///   <item><description>No dynamic slab growth yet; large headers/bodies can overflow the configured receive slab.</description></item>
///   <item><description>Request pipelining supported at header-level; body handling and chunked decoding not implemented here.</description></item>
///   <item><description>Minimal logging/telemetry; production builds should integrate structured, sampling-friendly logs.</description></item>
/// </list>
/// </remarks>
public sealed partial class ShrikeEngine { }