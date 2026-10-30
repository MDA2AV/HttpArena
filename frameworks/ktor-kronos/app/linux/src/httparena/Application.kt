package httparena

import io.ktor.http.ContentType
import io.ktor.http.content.ByteArrayContent
import io.ktor.http.content.TextContent
import io.ktor.server.application.Application
import io.ktor.server.application.ApplicationCall
import io.ktor.server.application.install
import io.ktor.server.engine.connector
import io.ktor.server.engine.embeddedServer
import io.ktor.server.kron.Kron
import io.ktor.server.request.receiveText
import io.ktor.server.request.uri
import io.ktor.server.response.respond
import io.ktor.server.routing.get
import io.ktor.server.routing.post
import io.ktor.server.routing.routing
import io.ktor.server.websocket.WebSockets
import io.ktor.server.websocket.webSocket
import kotlinx.coroutines.delay
import kotlin.native.runtime.GC
import kotlin.native.runtime.NativeRuntimeApi

/**
 * ktor-kronos: Ktor on kron, the Kotlin/Native port of the ioxide io_uring runtime, through the engine of the
 * MDA2AV/ktor fork (ktor-server-kron). The routes are the ktor entry's, answered the same way; only the engine and the
 * platform differ.
 *
 *     :8080  baseline, limited-conn, latency-1m, latency-10k   GET|POST /baseline11?a=&b=
 *            pipelined                                        GET      /pipeline
 *            async                                            GET      /delay/{ms}
 *            echo-ws, echo-ws-pipeline                        GET      /ws
 */
@OptIn(NativeRuntimeApi::class)
fun main() {
    // Kotlin/Native's collector starts from a heap sized for a phone and runs every few megabytes allocated, each
    // run stopping every reactor at a safepoint; from a 64 MiB floor it runs far less often.
    GC.minHeapBytes = intEnv("KRONOS_GC_MIN_HEAP_MB", 64).toLong() shl 20

    // A reactor per CPU of the container's cpuset, each pinned to its own: unpinned, the scheduler at times stacks
    // two reactors on one CPU and leaves another idle.
    val reactors = intEnv("KRONOS_REACTORS", availableProcessors())
    val pinned = env("KRONOS_PIN_REACTORS") != "0"
    println("[ktor-kronos] $reactors reactors${if (pinned) " (pinned)" else ""} on :8080")

    embeddedServer(Kron, configure = {
        connector { port = 8080 }
        reactorCount = reactors
        pinReactors = pinned
    }) {
        module()
    }.start(wait = true)
}

fun Application.module() {
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
