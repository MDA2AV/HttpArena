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
import io.ktor.server.plugins.compression.Compression
import io.ktor.server.plugins.compression.gzip
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
import kotlinx.coroutines.delay
import kotlinx.serialization.json.Json
import kron.tls.TlsOptions
import java.io.File

// The ktor entry's routes, answered the same way, on the kron engine: a reactor per CPU, each pinned to its own.
fun main() {
    val json = Json { ignoreUnknownKeys = true }
    val dataset = File(System.getenv("DATASET_PATH") ?: "/data/dataset.json").takeIf { it.exists() }
        ?.let { json.decodeFromString<List<DatasetItem>>(it.readText()) }
        ?: emptyList()
    val cert = System.getenv("TLS_CERT") ?: "/certs/server.crt"
    val key = System.getenv("TLS_KEY") ?: "/certs/server.key"

    embeddedServer(Kron, configure = {
        connector { port = 8080 }
        // The TLS profiles mount the certificate: without it, only the plaintext port opens.
        if (File(cert).exists() && File(key).exists()) {
            tlsConnector(8081, TlsOptions(certificatePath = cert, keyPath = key))
        }
        pinReactors = true
    }) {
        module(json, dataset)
    }.start(wait = true)
}

fun Application.module(json: Json, dataset: List<DatasetItem>) {
    install(WebSockets)

    val ok = ByteArrayContent("ok".toByteArray(), ContentType.Text.Plain)

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

        route("/json/{count}") {
            install(Compression) {
                gzip()
            }
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
