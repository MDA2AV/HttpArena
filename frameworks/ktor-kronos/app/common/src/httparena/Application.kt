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
import io.ktor.server.routing.Route
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.route
import io.ktor.server.routing.routing
import io.ktor.server.websocket.WebSockets
import io.ktor.server.websocket.webSocket
import kotlinx.coroutines.delay
import kotlinx.serialization.json.Json
import kron.tls.TlsOptions

/**
 * ktor-kronos: Ktor on kron, the ioxide io_uring runtime's Kotlin port, through the engine of the MDA2AV/ktor fork
 * (ktor-server-kron), natively or on the JVM: the same app either way, the Dockerfile's KRONOS_RUNTIME picks which.
 * The routes are the ktor entry's, answered the same way; only the engine and the platform differ.
 *
 *     :8080  baseline, limited-conn, latency-1m, latency-10k   GET|POST /baseline11?a=&b=
 *            pipelined                                        GET      /pipeline
 *            async                                            GET      /delay/{ms}
 *            json-comp (JVM only)                             GET      /json/{count}?m=
 *            echo-ws, echo-ws-pipeline                        GET      /ws
 *     :8081  json-tls (TLS)                                   GET      /json/{count}?m=
 *            8gbit (TLS)                                      POST     /echo
 *
 * [runtime] readies the runtime for that many reactors, and names it for the log.
 */
fun serve(runtime: (reactors: Int) -> String) {
    // A reactor per CPU of the container's cpuset, each pinned to its own: unpinned, the scheduler at times stacks
    // two reactors on one CPU and leaves another idle.
    val reactors = intEnv("KRONOS_REACTORS", availableProcessors())
    val pinned = env("KRONOS_PIN_REACTORS") != "0"

    val runtimeNote = runtime(reactors)

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
    println("[ktor-kronos] $reactors reactors$pinNote on :8080, $tlsNote, $runtimeNote")

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

// The 50 items the JSON profiles serve, read once; none when the dataset is not mounted.
private fun loadDataset(path: String): List<DatasetItem> {
    val bytes = readFile(path) ?: return emptyList()
    return json.decodeFromString<List<DatasetItem>>(bytes.decodeToString())
}

/** Ktor's Compression plugin with gzip, where Ktor has it: on the JVM. */
expect fun Route.installCompression()

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

        // The ktor entry's JSON route, as it is there: Ktor's ContentNegotiation serializes, and Ktor's Compression
        // gzips the result for a client that accepts gzip - on the JVM, as Ktor has no gzip on Kotlin/Native.
        route("/json/{count}") {
            installCompression()
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
