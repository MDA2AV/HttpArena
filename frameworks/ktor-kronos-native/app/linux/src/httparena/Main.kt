package httparena

import io.ktor.http.ContentType
import io.ktor.http.HttpStatusCode
import io.ktor.http.content.ByteArrayContent
import io.ktor.http.content.TextContent
import io.ktor.serialization.kotlinx.json.json
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
import kotlin.native.runtime.GC
import kotlin.native.runtime.NativeRuntimeApi
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.toKString
import kotlinx.coroutines.delay
import kotlinx.io.buffered
import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem
import kotlinx.io.readString
import kotlinx.serialization.json.Json
import kron.tls.TlsOptions
import platform.posix.getenv

// The ktor entry's routes, answered the same way, on the kron engine: a reactor per CPU, each pinned to its own.
@OptIn(NativeRuntimeApi::class)
fun main() {
    val json = Json { ignoreUnknownKeys = true }
    val dataset = readText(env("DATASET_PATH") ?: "/data/dataset.json")
        ?.let { json.decodeFromString<List<DatasetItem>>(it) }
        ?: emptyList()
    val cert = env("TLS_CERT") ?: "/certs/server.crt"
    val key = env("TLS_KEY") ?: "/certs/server.key"
    val reactors = allowedCpus()

    // The collector is not generational and stops every reactor to mark: at its default floor it runs back to back.
    GC.minHeapBytes = reactors * (64L shl 20)
    // By default it also puts every thread to sleep when the heap reaches its target before a collection ends.
    GC.pauseOnTargetHeapOverflow = false

    embeddedServer(Kron, configure = {
        connector { port = 8080 }
        // The TLS profiles mount the certificate: without it, only the plaintext port opens.
        if (SystemFileSystem.exists(Path(cert)) && SystemFileSystem.exists(Path(key))) {
            tlsConnector(8081, TlsOptions(certificatePath = cert, keyPath = key))
        }
        reactorCount = reactors
        pinReactors = true
    }) {
        module(json, dataset)
    }.start(wait = true)
}

fun Application.module(json: Json, dataset: List<DatasetItem>) {
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
            val body = call.receiveText().trim().toLongOrNull() ?: 0
            call.respondNumber(call.sumQueryParams() + body)
        }

        get("/delay/{ms}") {
            val ms = call.parameters["ms"] ?: "0"
            delay(ms.toLong())
            call.respond(TextContent(ms, ContentType.Text.Plain))
        }

        // No gzip: Ktor's Compression plugin is JVM-only.
        route("/json/{count}") {
            install(ContentNegotiation) {
                json(json)
            }
            get {
                if (dataset.isEmpty()) {
                    call.respondText("Dataset not loaded", ContentType.Text.Plain, HttpStatusCode.InternalServerError)
                    return@get
                }

                val count = (call.pathParameters["count"]?.toIntOrNull() ?: 0).coerceIn(0, dataset.size)
                val m = call.request.queryParameters["m"]?.toIntOrNull() ?: 1
                val items = List(count) { i ->
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
                call.respond(JsonResponse(items = items, count = count))
            }
        }

        // Collected first: a chunked request carries no length to answer with.
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

// The sum of the query's values, read off the target as the ktor entry does.
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

@OptIn(ExperimentalForeignApi::class)
private fun env(name: String): String? = getenv(name)?.toKString()

private fun readText(path: String): String? = Path(path).takeIf { SystemFileSystem.exists(it) }
    ?.let { SystemFileSystem.source(it).buffered().use { source -> source.readString() } }

// The CPUs the container's cpuset leaves this process, "0-31,64-95": Kotlin/Native's own count is every online CPU,
// more reactors than the engine can pin.
private fun allowedCpus(): Int = readText("/proc/self/status")!!.lineSequence()
    .first { it.startsWith("Cpus_allowed_list:") }
    .substringAfter(':').trim().split(',')
    .sumOf { range -> range.split('-').let { it.last().toInt() - it.first().toInt() + 1 } }
