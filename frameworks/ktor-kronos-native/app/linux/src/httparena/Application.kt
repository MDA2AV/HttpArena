package httparena

import io.ktor.http.ContentType
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.ByteArrayContent
import io.ktor.http.content.OutgoingContent
import io.ktor.http.content.TextContent
import io.ktor.http.withCharsetIfNeeded
import io.ktor.serialization.ContentConverter
import io.ktor.serialization.kotlinx.KotlinxSerializationConverter
import io.ktor.serialization.kotlinx.serializerForTypeInfo
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCall
import io.ktor.server.application.install
import io.ktor.server.engine.connector
import io.ktor.server.engine.embeddedServer
import io.ktor.server.kron.Kron
import io.ktor.server.plugins.contentnegotiation.ContentNegotiation
import io.ktor.server.request.receive
import io.ktor.server.request.receiveText
import io.ktor.server.request.uri
import io.ktor.server.response.respond
import io.ktor.server.response.respondBytes
import io.ktor.server.response.respondText
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.route
import io.ktor.server.routing.routing
import io.ktor.server.websocket.WebSockets
import io.ktor.server.websocket.webSocket
import io.ktor.util.reflect.TypeInfo
import io.ktor.utils.io.charsets.Charset
import kotlin.native.runtime.GC
import kotlin.native.runtime.NativeRuntimeApi
import kotlinx.coroutines.delay
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.InternalSerializationApi
import kotlinx.serialization.KSerializer
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.internal.ESCAPE_STRINGS
import kotlinx.serialization.json.internal.InternalJsonWriter
import kotlinx.serialization.json.internal.encodeByWriter
import kron.tls.TlsOptions

/**
 * ktor-kronos-native: Ktor on kron, the ioxide io_uring runtime's Kotlin port, through the engine of the MDA2AV/ktor
 * fork (ktor-server-kron), as one Kotlin/Native binary; the ktor-kronos entry runs the same app on the JVM. The routes
 * are the ktor entry's, answered the same way; only the engine and the platform differ.
 *
 *     :8080  baseline, limited-conn, latency-1m, latency-10k   GET|POST /baseline11?a=&b=
 *            pipelined                                        GET      /pipeline
 *            async                                            GET      /delay/{ms}
 *            echo-ws, echo-ws-pipeline                        GET      /ws
 *     :8081  json-tls (TLS)                                   GET      /json/{count}?m=
 *            8gbit (TLS)                                      POST     /echo
 */
@OptIn(NativeRuntimeApi::class)
fun main() {
    // A reactor per CPU of the container's cpuset, each pinned to its own: unpinned, the scheduler at times stacks
    // two reactors on one CPU and leaves another idle.
    val reactors = intEnv("KRONOS_REACTORS", availableProcessors())
    val pinned = env("KRONOS_PIN_REACTORS") != "0"

    // Kotlin/Native's collector is not generational: it marks everything live on every run, stops every reactor to do
    // it, and puts allocating threads to sleep when it falls behind. Ktor allocates some sixty objects a request, so a
    // heap floor sized for a phone has it running back to back, the reactors idle - and one too high lets tens of GiB
    // of garbage pile up for each run to sweep, the reactors as idle. On the arena's 64 cores, 64 MiB per reactor
    // served 3.5 times what 512 did.
    val heapMb = intEnv("KRONOS_GC_MIN_HEAP_MB", 64 * reactors)
    GC.minHeapBytes = heapMb.toLong() shl 20

    // The harness mounts the certificate for the TLS profiles. Without it the TLS port does not open, and the
    // plaintext profiles still run.
    val certPath = env("TLS_CERT") ?: "/certs/server.crt"
    val keyPath = env("TLS_KEY") ?: "/certs/server.key"
    val tls = fileExists(certPath) && fileExists(keyPath)

    // As on kron's own entry, the kernel makes the TLS records where it has the tls module (kernel TX), one pass over
    // the slab's plaintext; receive stays on BoringSSL. Elsewhere BoringSSL does both.
    val kernelTx = env("KRONOS_KERNEL_TX")?.let { it != "0" } ?: kernelTlsAvailable()

    val dataset = loadDataset(env("DATASET_PATH") ?: "/data/dataset.json")

    val tlsNote = when {
        !tls -> "no tls certificate"
        kernelTx -> "tls on :8081, kernel tx"
        else -> "tls on :8081, boringssl tx"
    }
    val pinNote = if (pinned) " (pinned)" else ""
    println("[ktor-kronos-native] $reactors reactors$pinNote on :8080, $tlsNote, GC heap floor $heapMb MiB")

    embeddedServer(Kron, configure = {
        connector { port = 8080 }
        if (tls) {
            tlsConnector(8081, TlsOptions(certificatePath = certPath, keyPath = keyPath, kernelTx = kernelTx))
        }
        reactorCount = reactors
        pinReactors = pinned
    }) {
        module(dataset)
    }.start(wait = true)
}

private val json = Json { ignoreUnknownKeys = true }

/**
 * ContentNegotiation's JSON as Ktor's own converter makes it - kotlinx.serialization's encoder and escaping - written
 * straight to UTF-8 bytes: encodeToString takes its buffer from one process-wide pool, under a lock every reactor
 * queues on.
 */
private class JsonBytesConverter(private val json: Json) : ContentConverter by KotlinxSerializationConverter(json) {
    @OptIn(InternalSerializationApi::class, ExperimentalSerializationApi::class)
    override suspend fun serialize(
        contentType: ContentType,
        charset: Charset,
        typeInfo: TypeInfo,
        value: Any?,
    ): OutgoingContent {
        @Suppress("UNCHECKED_CAST")
        val serializer = json.serializersModule.serializerForTypeInfo(typeInfo) as KSerializer<Any?>
        val writer = Utf8JsonWriter()
        encodeByWriter(json, writer, serializer, value)
        return ByteArrayContent(writer.bytes.copyOf(writer.size), contentType.withCharsetIfNeeded(charset))
    }
}

/** kotlinx.serialization's JSON writer interface over a byte array of the call's own. */
@OptIn(InternalSerializationApi::class)
private class Utf8JsonWriter : InternalJsonWriter {
    var bytes = ByteArray(8192)
    var size = 0

    private fun ensure(extra: Int) {
        if (size + extra > bytes.size) {
            bytes = bytes.copyOf(maxOf(size + extra, bytes.size * 2))
        }
    }

    override fun writeLong(value: Long) {
        if (value == Long.MIN_VALUE) {
            return write(value.toString())
        }

        ensure(20)
        var v = value
        if (v < 0) {
            bytes[size++] = '-'.code.toByte()
            v = -v
        }

        val end = size + digits(v)
        var at = end
        do {
            bytes[--at] = ('0'.code + (v % 10).toInt()).toByte()
            v /= 10
        } while (v != 0L)
        size = end
    }

    override fun writeChar(char: Char) {
        ensure(4)
        putChar(char.code)
    }

    override fun write(text: String) {
        ensure(text.length * 3)
        putString(text)
    }

    // As kotlinx's own writer escapes, from its table: the quote, the backslash and the control characters.
    override fun writeQuoted(text: String) {
        ensure(text.length * 6 + 2)
        bytes[size++] = '"'.code.toByte()
        putString(text)
        bytes[size++] = '"'.code.toByte()
    }

    override fun release() {}

    private fun putString(text: String) {
        var i = 0
        while (i < text.length) {
            val c = text[i].code
            if (c < ESCAPE_STRINGS.size && ESCAPE_STRINGS[c] != null) {
                val escape = ESCAPE_STRINGS[c]!!
                for (e in escape) {
                    bytes[size++] = e.code.toByte()
                }
            } else if (c in 0xD800..0xDBFF && i + 1 < text.length && text[i + 1].code in 0xDC00..0xDFFF) {
                val codePoint = 0x10000 + ((c - 0xD800) shl 10) + (text[i + 1].code - 0xDC00)
                bytes[size++] = (0xF0 or (codePoint shr 18)).toByte()
                bytes[size++] = (0x80 or ((codePoint shr 12) and 0x3F)).toByte()
                bytes[size++] = (0x80 or ((codePoint shr 6) and 0x3F)).toByte()
                bytes[size++] = (0x80 or (codePoint and 0x3F)).toByte()
                i++
            } else {
                putChar(c)
            }
            i++
        }
    }

    // One UTF-16 unit; a lone surrogate becomes '?', as String.encodeToByteArray makes it.
    private fun putChar(c: Int) {
        when {
            c < 0x80 -> bytes[size++] = c.toByte()
            c < 0x800 -> {
                bytes[size++] = (0xC0 or (c shr 6)).toByte()
                bytes[size++] = (0x80 or (c and 0x3F)).toByte()
            }
            c in 0xD800..0xDFFF -> bytes[size++] = '?'.code.toByte()
            else -> {
                bytes[size++] = (0xE0 or (c shr 12)).toByte()
                bytes[size++] = (0x80 or ((c shr 6) and 0x3F)).toByte()
                bytes[size++] = (0x80 or (c and 0x3F)).toByte()
            }
        }
    }

    private fun digits(v: Long): Int {
        var n = 1
        var x = v
        while (x >= 10) {
            x /= 10
            n++
        }
        return n
    }
}

// The 50 items the JSON profiles serve, read once; none when the dataset is not mounted.
private fun loadDataset(path: String): List<DatasetItem> {
    val bytes = readFile(path) ?: return emptyList()
    return json.decodeFromString<List<DatasetItem>>(bytes.decodeToString())
}

fun Application.module(dataset: List<DatasetItem>) {
    install(WebSockets)

    val ok = ByteArrayContent("ok".encodeToByteArray(), ContentType.Text.Plain)

    routing {
        get("/pipeline") {
            call.respond(ok)
        }

        get("/baseline11") {
            call.respondNumber(call.sumQueryParams())
        }

        post("/baseline11") {
            val sum = call.sumQueryParams()
            val body = call.receiveText().trim().toLongOrNull() ?: 0
            call.respondNumber(sum + body)
        }

        // A wait on the reactor's own ring (IORING_OP_TIMEOUT), the engine's delay(): no timer thread
        get("/delay/{ms}") {
            val ms = call.parameters["ms"] ?: "0"
            delay(ms.toLong())
            call.respond(TextContent(ms, ContentType.Text.Plain))
        }

        // The ktor entry's JSON route, less its gzip, which Ktor has only on the JVM: Ktor's ContentNegotiation
        // serializes.
        route("/json/{count}") {
            install(ContentNegotiation) {
                register(ContentType.Application.Json, JsonBytesConverter(json))
            }
            get {
                if (dataset.isEmpty()) {
                    call.respondText("Dataset not loaded", ContentType.Text.Plain, HttpStatusCode.InternalServerError)
                    return@get
                }

                val count = (call.pathParameters["count"]?.toIntOrNull() ?: 0).coerceIn(0, dataset.size)
                val m = call.request.queryParameters["m"]?.toIntOrNull() ?: 1
                val processed = List(count) { i ->
                    val d = dataset[i]
                    ProcessedItem(
                        id = d.id,
                        name = d.name,
                        category = d.category,
                        price = d.price,
                        quantity = d.quantity,
                        active = d.active,
                        tags = d.tags,
                        rating = d.rating,
                        total = d.price.toLong() * d.quantity * m,
                    )
                }
                call.respond(JsonResponse(items = processed, count = count))
            }
        }

        // The body back as it came, collected first: a chunked request carries no length to answer with.
        post("/echo") {
            val body = call.receive<ByteArray>()
            call.respondBytes(body, ContentType.Application.OctetStream)
        }

        webSocket("/ws") {
            for (message in incoming) {
                send(message)
            }
        }
    }
}

// The sum of the query's values, read off the target as the ktor entry does, with no parameter map made for it.
private fun ApplicationCall.sumQueryParams(): Long {
    val uri = request.uri
    var start = -1
    var sum = 0L
    for (i in uri.indices) {
        when (uri[i]) {
            '=' -> start = i + 1
            '&' -> {
                if (start >= 0) sum += uri.substring(start, i).toLongOrNull() ?: 0
                start = -1
            }
        }
    }
    if (start >= 0) sum += uri.substring(start).toLongOrNull() ?: 0
    return sum
}

private suspend fun ApplicationCall.respondNumber(value: Long) =
    respond(TextContent(value.toString(), ContentType.Text.Plain))
