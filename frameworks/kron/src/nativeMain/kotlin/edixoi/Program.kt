package edixoi

import kron.IOException
import kron.KronServer
import kron.Memory
import kron.RecvItem
import kron.RecvSnapshot
import kron.RingTimer
import kron.ServerConfig
import kron.TcpConnection
import kron.TcpOptions
import kron.tls.TlsOptions
import kron.tls.TlsService
import kron.tls.TlsSession
import kotlin.native.runtime.GC
import kotlin.native.runtime.NativeRuntimeApi

/**
 * kron - edixoi on Kotlin/Native: the arena's HTTP/1.1 profiles on kron, the native port of ioxide, hand-written on its
 * raw recv/send API. One reactor per core, each owning its ring and its share of the SO_REUSEPORT listeners; no
 * framework sits between the socket and the answer.
 *
 *     :8080  baseline, limited-conn, latency-1m, latency-10k   GET|POST /baseline11?a=&b=
 *            async                                            GET      /delay/{ms}
 *     :8081  json-tls                                          GET      /json/{count}?m=N
 *            8gbit                                             POST     /echo
 *
 * One handler serves both doors: a connection carries the port it arrived on, and the only difference is whether
 * a [TlsSession] sits in front of the bytes. See [Http1] for the parsing and the routing; this file is the transport.
 */
@OptIn(NativeRuntimeApi::class)
fun main() {
    // Kotlin/Native's collector starts from a heap sized for a phone and runs every few megabytes allocated, each
    // run stopping every reactor at a safepoint. From a 64 MiB floor it runs far less often; the JVM entries start
    // from a much larger heap anyway.
    GC.minHeapBytes = intEnv("EDIXOI_GC_MIN_HEAP_MB", 64).toLong() shl 20

    val port = intEnv("EDIXOI_PORT", 8080)
    val tlsPort = intEnv("EDIXOI_TLS_PORT", 8081)
    // availableProcessors counts logical CPUs within the container's cpuset, as edixoi's ProcessorCount does.
    val reactors = intEnv("EDIXOI_REACTORS", minOf(availableProcessors(), 64))

    // The harness mounts both. Without them the TLS door does not open and the plaintext profiles still run,
    // which is what makes this runnable outside the harness.
    val certPath = env("TLS_CERT") ?: "/certs/server.crt"
    val keyPath = env("TLS_KEY") ?: "/certs/server.key"
    val tls = fileExists(certPath) && fileExists(keyPath)

    val dataset = Dataset.load(env("EDIXOI_DATASET") ?: "/data/dataset.json")

    // One handler, two doors, and each reactor on a CPU of its own: unpinned, the scheduler at times stacks two
    // reactors on one CPU and leaves another idle. Everything else is left at kron's own defaults, as on edixoi.
    val pinned = boolEnv("EDIXOI_PIN_REACTORS", true)
    val config = ServerConfig(
        reactorCount = reactors,
        pinReactors = pinned,
        tcp = TcpOptions(port = port, extraPorts = if (tls) intArrayOf(tlsPort) else IntArray(0)),
    )

    // The mounted certificate as it is: ALPN is already http/1.1, which both TLS profiles require. Kernel TX is
    // the one knob off its default, as on edixoi: the kernel makes the records from the slab's plaintext, one pass
    // over the bytes. Receive stays on BoringSSL. On by default only where the kernel has the tls ULP, so a host
    // without the module still serves TLS, through BoringSSL both ways.
    val tlsOptions = TlsOptions(
        certificatePath = certPath,
        keyPath = keyPath,
        kernelTx = boolEnv("EDIXOI_KERNEL_TX", kernelTlsAvailable()),
        kernelRx = boolEnv("EDIXOI_KERNEL_RX", false),
    )

    val server = Server(reactors, tlsPort, dataset, if (tls) tlsOptions else null)

    val tx = if (tlsOptions.kernelTx) "kernel tx" else "boringssl tx"
    println(
        "[kron] $reactors reactors${if (pinned) " (pinned)" else ""} on :$port" +
            (if (tls) " + :$tlsPort tls ($tx)" else " (no tls: certificate not mounted)") +
            ", dataset=${dataset.count} items (availableProcessors=${availableProcessors()})",
    )

    KronServer(config, onStart = server::start, handler = server::serve).start().join()
}

private class Server(reactors: Int, private val tlsPort: Int, private val dataset: Dataset, private val tlsOptions: TlsOptions?) {
    // Per reactor, by id: the parser and its buffers, the TLS context, and the item the feed takes completions
    // into. A reactor runs one thread and none of them is used across a suspension, which makes them shareable
    // and a connection free to open - the limited-conn profile opens a quarter of a million a second.
    private val parsers = arrayOfNulls<Http1>(reactors)
    private val tlsServices = arrayOfNulls<TlsService>(reactors)
    private val items = arrayOfNulls<RecvItem>(reactors)

    fun start(reactor: kron.Reactor) {
        parsers[reactor.id] = Http1(dataset)
        items[reactor.id] = RecvItem()
        // Built on the reactor's thread too, so the BoringSSL context belongs to the thread that uses it.
        if (tlsOptions != null) tlsServices[reactor.id] = TlsService.start(reactor, tlsOptions)
    }

    /**
     * One connection, start to finish, on the reactor thread that accepted it. Every suspension resumes right back
     * on it, so nothing here is shared and nothing is locked.
     */
    suspend fun serve(conn: TcpConnection) {
        val id = conn.reactor.id
        val session = Session(conn, parsers[id]!!, items[id]!!)
        try {
            if (conn.listenerPort == tlsPort) {
                session.tls = tlsServices[id]!!.accept(conn)

                // A request can ride in with the handshake's last flight, so it is fed and served before the loop
                // parks on a read that would otherwise never come.
                session.feedHandshakeRemainder()
                if (session.pump()) conn.flush()
            }

            while (!session.close) {
                val snapshot = conn.read()
                session.feed(snapshot)
                if (session.pump()) conn.flush()
                if (snapshot.isClosed) return
            }

            // Connection: close is an HTTP decision, so honouring it is this entry's job - kron moves bytes and
            // knows nothing about HTTP. Half-closing the write side puts the FIN the peer is waiting for on the
            // wire; the descriptor stays kron's, which closes it once its own reference goes.
            conn.shutdownWrite()
        } catch (e: IOException) {
            // A failed handshake or a broken record ends the connection, as the peer going away does.
        } finally {
            session.tls?.close()
        }
    }
}

/**
 * One connection's state: the bytes not yet answered, the timer the delay endpoint waits on, and the TLS session
 * when there is one. It exists so the read loop above stays a read loop - the waiting is here, where the state it
 * resumes into lives.
 */
private class Session(private val conn: TcpConnection, private val http: Http1, private val item: RecvItem) : Sink {
    private val carry = Carry()
    private var timer: RingTimer? = null

    var tls: TlsSession? = null
    var close = false

    override fun write(bytes: ByteArray, offset: Int, length: Int) {
        val session = tls
        if (session == null) conn.write(bytes, offset, length) else session.write(conn, bytes, offset, length)
    }

    /** Plaintext the handshake's final flight carried in ahead of the first read. */
    fun feedHandshakeRemainder() {
        val session = tls!!
        val n = session.drainPlaintext()
        carry.append(session.plaintext, n)
    }

    /** Everything the ring delivered, decrypted when this is a TLS connection. */
    fun feed(snapshot: RecvSnapshot) {
        val session = tls
        while (conn.tryGetItem(snapshot, item)) {
            if (!item.hasBuffer) continue
            if (session == null) {
                carry.append(item.address, item.length)
            } else {
                val n = session.decrypt(item.address, item.length)   // sets plaintext: read it after
                carry.append(session.plaintext, n)
            }
            conn.returnBuffer(item)
        }
    }

    /**
     * Answers everything held, waiting on the ring for any request that asked to be delayed. True when something
     * was written and the caller owes a flush.
     *
     * Its one suspend call is a tail call, so it needs no coroutine frame: only a delayed request, which waits
     * anyway, pays for one. Kotlin/Native would otherwise allocate a frame per request, and collect each one.
     */
    suspend fun pump(): Boolean {
        answered = false
        if (serveReady() == Http1.NO_DELAY) return answered || close
        return waitAndServe()
    }

    // Set by serveReady, read by pump and waitAndServe.
    private var answered = false

    /** Answers what needs no waiting: the delay the next request asked for, or [Http1.NO_DELAY]. */
    private fun serveReady(): Int {
        val consumed = http.serve(this, carry.buffer, carry.length, close)
        close = http.close
        carry.consume(consumed)
        if (consumed > 0) answered = true
        return http.delayMs
    }

    private suspend fun waitAndServe(): Boolean {
        var delayMs = http.delayMs
        while (delayMs != Http1.NO_DELAY) {
            // The wait rides this reactor's ring: the deadline goes to the kernel with the submission and the
            // completion resumes this on the same thread, so a held connection costs a deadline, not a thread. One
            // timer per connection, re-armed - a connection only ever waits on one request at a time.
            val wait = timer ?: RingTimer(conn.reactor).also { timer = it }
            wait.delay(delayMs.toLong())

            http.writeDelayed(this, delayMs, close)
            answered = true
            delayMs = serveReady()
        }

        return answered || close
    }
}

/**
 * What has arrived and not yet been answered. A read that carries whole requests leaves it empty again; a request
 * split across reads is held here until the rest of it lands. Per connection it has to be, so it is the one buffer
 * paid for on every accept: it starts empty and grows to what this connection actually sees.
 */
private class Carry {
    var buffer = ByteArray(0)
        private set
    var length = 0
        private set

    fun append(address: Long, count: Int) {
        if (count == 0) return
        if (buffer.size < length + count) buffer = buffer.copyOf(maxOf(length + count, buffer.size * 2))
        Memory.copy(address, buffer, length, count)
        length += count
    }

    fun consume(count: Int) {
        if (count >= length) {
            length = 0
            return
        }
        buffer.copyInto(buffer, 0, count, length)
        length -= count
    }
}

private fun intEnv(name: String, fallback: Int): Int = env(name)?.toIntOrNull() ?: fallback

private fun boolEnv(name: String, fallback: Boolean): Boolean = when (env(name)?.lowercase()) {
    "1", "true", "yes" -> true
    "0", "false", "no" -> false
    else -> fallback
}
