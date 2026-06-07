// ReSharper disable always CheckNamespace
// ReSharper disable always SuggestVarOrType_BuiltInTypes
// (var is avoided intentionally in this project so that concrete types are visible at call sites.)
// ReSharper disable always StackAllocInsideLoop
// ReSharper disable always ClassCannotBeInstantiated
#pragma warning disable CA2014

namespace Shrike;

/// <summary>
/// Linux interop surface for a high-performance, epoll-driven TCP server.
/// 
/// Design goals:
/// - **Minimal marshaling overhead**: prefer blittable types (e.g., pointers, ints).
/// - **Explicit error handling**: all functions are marked <see cref="DllImportAttribute.SetLastError"/>. 
///   Use <c>Marshal.GetLastPInvokeError()</c> immediately after a failure to read <c>errno</c>.
/// - **Unsafe-friendly**: exposes pointer overloads for zero-copy recv/send.
/// 
/// Platform notes:
/// - Constants can differ across libc/architectures/kernels. The values here target
///   mainstream Linux/glibc on x86_64. If you target other distros/architectures, verify
///   these values against system headers (<c>bits/socket.h</c>, <c>fcntl.h</c>, <c>sys/epoll.h</c>, <c>sys/eventfd.h</c>).
/// - Network byte order: ports must be big-endian (use htons); addresses must be set appropriately.
/// - SIGPIPE: either ignore SIGPIPE process-wide or pass <see cref="MSG_NOSIGNAL"/> to <c>send</c>.
/// </summary>
internal static unsafe class Native
{
    // =========================
    //        P/Invoke
    // =========================

    /// <summary>
    /// Create a socket. Typically <c>domain=AF_INET</c>, <c>type=SOCK_STREAM</c>, <c>protocol=IPPROTO_TCP</c>.
    /// Returns a file descriptor (>= 0) on success, or -1 on error (check errno).
    /// </summary>
    [DllImport("libc", SetLastError = true)] internal static extern int socket(int domain, int type, int protocol);

    /// <summary>
    /// Bind a socket to an address/port. Use <see cref="sockaddr_in"/> for IPv4.
    /// Returns 0 on success, -1 on error.
    /// </summary>
    [DllImport("libc", SetLastError = true)] internal static extern int bind(int sockfd, ref sockaddr_in addr, uint addrlen);

    /// <summary>
    /// Mark a bound socket as passive (accept incoming connections).
    /// <paramref name="backlog"/> is the kernel queue length hint.
    /// Returns 0 on success, -1 on error.
    /// </summary>
    [DllImport("libc", SetLastError = true)] internal static extern int listen(int sockfd, int backlog);

    /// <summary>
    /// Accept a new connection. <c>flags</c> can include <see cref="SOCK_NONBLOCK"/> and <see cref="SOCK_CLOEXEC"/> 
    /// to atomically configure the accepted FD. Returns new client FD or -1 on error.
    /// Use <c>Marshal.GetLastPInvokeError()</c> to check for <see cref="EAGAIN"/>/<see cref="EWOULDBLOCK"/> in edge-triggered loops.
    /// </summary>
    [DllImport("libc", SetLastError = true)] internal static extern int accept4(int sockfd, IntPtr addr, IntPtr addrlen, int flags);

    /// <summary>
    /// Set a socket option (int value). Common options: <see cref="SO_REUSEADDR"/>, TCP_NODELAY, etc.
    /// Returns 0 on success, -1 on error.
    /// </summary>
    [DllImport("libc", SetLastError = true)] internal static extern int setsockopt(int sockfd, int level, int optname, ref int optval, uint optlen);

    /// <summary>
    /// Set <c>SO_LINGER</c> using <see cref="Linger"/> struct.
    /// Returns 0 on success, -1 on error.
    /// </summary>
    [DllImport("libc", SetLastError = true)] internal static extern int setsockopt(int sockfd, int level, int optname, ref Linger optval, uint optlen);

    /// <summary>
    /// File control. Typical usage: get/set O_NONBLOCK on a socket.
    /// Returns result per command, or -1 on error.
    /// </summary>
    [DllImport("libc", SetLastError = true)] internal static extern int fcntl(int fd, int cmd, int arg);

    /// <summary>
    /// Close a file descriptor (socket or epoll/eventfd). Returns 0 on success, -1 on error.
    /// </summary>
    [DllImport("libc", SetLastError = true)] internal static extern int close(int fd);

    /// <summary>
    /// Read from a file descriptor into unmanaged memory.
    /// For sockets, prefer <see cref="recv(int, IntPtr, ulong, int)"/>.
    /// Returns bytes read (&gt;=0) or -1 on error.
    /// </summary>
    [DllImport("libc", SetLastError = true)] internal static extern long read(int fd, IntPtr buf, ulong count);

    /// <summary>
    /// Write to a file descriptor from unmanaged memory.
    /// For sockets, prefer <see cref="send(int, IntPtr, ulong, int)"/>.
    /// Returns bytes written (&gt;=0) or -1 on error.
    /// </summary>
    [DllImport("libc", SetLastError = true)] internal static extern long write(int fd, IntPtr buf, ulong count);

    /// <summary>
    /// Receive from a socket into unmanaged memory. Returns bytes received (&gt;=0), 0 on orderly shutdown, or -1 on error.
    /// Set <c>flags</c> to 0 for normal reads.
    /// </summary>
    [DllImport("libc", SetLastError = true)] internal static extern long recv(int sockfd, IntPtr buf, ulong len, int flags);

    /// <summary>
    /// Receive from a socket into a raw pointer. Equivalent to the IntPtr overload, but avoids extra pinning overhead when you already have a pointer.
    /// </summary>
    [DllImport("libc", SetLastError = true)] internal static extern long recv(int sockfd, byte* buf, ulong len, int flags);

    /// <summary>
    /// Send to a socket from unmanaged memory. Returns bytes sent (&gt;=0) or -1 on error.
    /// Consider passing <see cref="MSG_NOSIGNAL"/> in <c>flags</c> to avoid SIGPIPE on closed peers.
    /// </summary>
    [DllImport("libc", SetLastError = true)] internal static extern long send(int sockfd, IntPtr buf, ulong len, int flags);

    /// <summary>
    /// Send to a socket from a raw pointer (long length).
    /// </summary>
    [DllImport("libc", SetLastError = true)] internal static extern long send(int sockfd, byte* buf, long len, int flags);

    /// <summary>
    /// Send to a socket from a raw <c>void*</c> and <c>nuint</c> length.
    /// This signature maps closely to the native prototype and can reduce marshaling overhead in hot paths.
    /// </summary>
    [DllImport("libc", SetLastError = true)] public static extern nint send(int sockfd, void* buf, nuint len, int flags);

    /// <summary>
    /// Create an epoll instance. Returns an epoll file descriptor (&gt;=0) or -1 on error.
    /// Use <see cref="EPOLL_CLOEXEC"/> to set close-on-exec at creation time.
    /// </summary>
    [DllImport("libc", SetLastError = true)] internal static extern int epoll_create1(int flags);

    /// <summary>
    /// Control the epoll interest list (add/mod/del). The <c>ev</c> points to an <c>epoll_event</c> struct in unmanaged memory.
    /// Returns 0 on success, -1 on error.
    /// </summary>
    [DllImport("libc", SetLastError = true)] internal static extern int epoll_ctl(int epfd, int op, int fd, IntPtr ev);

    /// <summary>
    /// Wait for events. <c>events</c> points to a contiguous array of <c>epoll_event</c> (maxevents elements).
    /// Returns number of events (&gt;=0) or -1 on error. Use timeout &lt; 0 to block indefinitely.
    /// </summary>
    [DllImport("libc", SetLastError = true)] internal static extern int epoll_wait(int epfd, IntPtr events, int maxevents, int timeout);

    /// <summary>
    /// Create an eventfd (userspace semaphore/notification). Great for waking worker threads from another thread.
    /// Returns fd (&gt;=0) or -1 on error.
    /// </summary>
    [DllImport("libc", SetLastError = true)] internal static extern int eventfd(uint initval, int flags);
    
    [DllImport("libc", SetLastError = true)] internal static extern int sched_setaffinity(int pid, IntPtr cpusetsize, ref ulong mask);
    
    [DllImport("libc", SetLastError = true)] internal static extern int sched_setaffinity(int pid, IntPtr cpusetsize, ref cpu_set_t mask);
    
    [DllImport("libc")] internal static extern int gettid(); // Linux thread id
    
    // =========================
    //     Struct definitions
    // =========================

    /// <summary>
    /// IPv4 address (network byte order).
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct in_addr
    {
        /// <summary>
        /// Address in network byte order (big-endian). 0 == INADDR_ANY.
        /// </summary>
        public uint s_addr;
    }

    /// <summary>
    /// IPv4 socket address. Must be passed with <c>addrlen = (uint)sizeof(sockaddr_in)</c>.
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct sockaddr_in
    {
        /// <summary>Address family (AF_INET).</summary>
        public ushort sin_family;

        /// <summary>Port in network byte order (use htons).</summary>
        public ushort sin_port;

        /// <summary>IPv4 address (use INADDR_ANY or a specific address in network byte order).</summary>
        public in_addr sin_addr;

        /// <summary>
        /// Padding to match native layout (8 bytes). Must be present for correct size.
        /// It need not be initialized for normal usage; the kernel ignores it.
        /// </summary>
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 8)]
        public byte[] sin_zero;
    }

    /// <summary>
    /// linger option for <c>SO_LINGER</c>.
    /// If <c>l_onoff != 0</c>, close() will block up to <c>l_linger</c> seconds to flush pending data.
    /// Be careful: enabling linger can cause unexpected blocking on close.
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    internal struct Linger
    {
        public int l_onoff;
        public int l_linger;
    }


    // =========================
    //         Constants
    // =========================
    // Socket families/types/protocols
    internal const int AF_INET      = 2;
    internal const int SOCK_STREAM  = 1;
    internal const int IPPROTO_TCP  = 6;

    // setsockopt levels / names
    internal const int SOL_SOCKET   = 1;
    internal const int SO_REUSEADDR = 2;
    internal const int SO_REUSEPORT = 15;
    internal const int SO_LINGER    = 13;
    /// <summary>
    /// TCP_NODELAY (disable Nagle). Linux defines this at level IPPROTO_TCP with optname=1.
    /// (Kept here as constant=1; use level=IPPROTO_TCP when calling setsockopt.)
    /// </summary>
    internal const int TCP_NODELAY  = 1;

    // fcntl / file status flags
    internal const int O_NONBLOCK   = 0x800; // Verify per-arch.
    internal const int F_GETFL      = 3;
    internal const int F_SETFL      = 4;

    // epoll events
    internal const int EPOLLIN      = 0x001;
    internal const int EPOLLOUT     = 0x004;
    internal const int EPOLLERR     = 0x008;
    internal const int EPOLLHUP     = 0x010;
    internal const int EPOLLRDHUP   = 0x2000;
    internal const uint EPOLLET     = 0x80000000;
    internal const uint EPOLLONESHOT = 0x40000000;

    // epoll_ctl ops
    internal const int EPOLL_CTL_ADD = 1;
    internal const int EPOLL_CTL_DEL = 2;
    internal const int EPOLL_CTL_MOD = 3;

    // CLOEXEC / NONBLOCK flags (creation-time)
    /// <summary>Close-on-exec for epoll_create1/eventfd. (Verify on your target kernel/arch.)</summary>
    internal const int EPOLL_CLOEXEC = 0x80000;

    /// <summary>
    /// On many Linux systems, SOCK_CLOEXEC is 0x1000000 (not 0x80000).
    /// Validate this constant on your target platform if you pass it to <c>socket()</c> or <c>accept4()</c>.
    /// </summary>
    internal const int SOCK_CLOEXEC  = 0x80000;

    /// <summary>Creation-time nonblocking for socket/accept4.</summary>
    internal const int SOCK_NONBLOCK = 0x800;

    // eventfd flags
    internal const int EFD_NONBLOCK = 0x800;
    internal const int EFD_CLOEXEC  = 0x80000;

    // send/recv flags
    /// <summary>
    /// Suppress SIGPIPE on send. Alternatively, ignore SIGPIPE process-wide.
    /// </summary>
    internal const int MSG_NOSIGNAL = 0x4000;

    // Common errno values we branch on in tight loops
    internal const int EINTR          = 4;
    internal const int EAGAIN         = 11;
    internal const int EWOULDBLOCK    = 11;
    internal const int EPIPE          = 32;
    internal const int ECONNABORTED   = 103;
    internal const int ECONNRESET     = 104;
    
    public static void PinCurrentThreadToCpu(int cpuIndex)
    {
        if (cpuIndex < 0 || cpuIndex >= Environment.ProcessorCount)
            throw new ArgumentOutOfRangeException(nameof(cpuIndex));

        unsafe
        {
            var set = new cpu_set_t();
            int word = cpuIndex / 64;
            int bit  = cpuIndex % 64;
            set.Bits[word] = 1UL << bit;

            int tid = gettid();
            int ret = sched_setaffinity(tid, (IntPtr)sizeof(cpu_set_t), ref set);
            if (ret != 0)
                throw new InvalidOperationException($"sched_setaffinity failed with errno {Marshal.GetLastPInvokeError()}");
        }
    }
}

internal unsafe struct cpu_set_t
{
    public fixed ulong Bits[16]; // 1024 bits (enough for up to 1024 CPUs)
}