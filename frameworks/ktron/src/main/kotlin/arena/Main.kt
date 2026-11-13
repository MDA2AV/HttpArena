package arena

import com.ghost.serialization.Ghost
import ktron.Compression
import ktron.Context
import ktron.Ktron
import ktron.KtronOptions
import ktron.KtronTls
import java.io.File

/**
 * HttpArena's HTTP/1.1 profiles on Ktron.
 *
 *     :8080  baseline, limited-conn, latency     GET|POST /baseline11?a=&b=
 *            pipelined                            GET      /pipeline
 *            async                                GET      /delay/{ms}
 *            json-comp                            GET      /json/{count}?m=N
 *     :8081  json-tls                             GET      /json/{count}?m=N
 *            8gbit                                POST     /echo
 */
fun main() {
    val cert = env("TLS_CERT") ?: "/certs/server.crt"
    val key = env("TLS_KEY") ?: "/certs/server.key"
    val tls = if (File(cert).exists() && File(key).exists()) {
        KtronTls(cert, key, port = 8081, kernelTx = env("KTRON_KERNEL_TX") != "0", kernelRx = env("KTRON_KERNEL_RX") == "1")
    } else {
        null
    }
    val reactors = env("KTRON_REACTORS")?.toIntOrNull() ?: Runtime.getRuntime().availableProcessors()
    val dataset = loadDataset(env("KTRON_DATASET") ?: "/data/dataset.json")

    val app = Ktron(KtronOptions(port = env("KTRON_PORT")?.toIntOrNull() ?: 8080, reactors = reactors, tls = tls))

    // Per reactor: a request runs on one thread start to finish, so its items and response object are its own.
    val json = Array(reactors) { JsonState(dataset) }

    // gzip for whoever accepts it (json-comp), nothing for whoever does not (json-tls).
    app.use(Compression())

    app.get("/baseline11") { ctx -> ctx.response.text(querySum(ctx)) }
    app.post("/baseline11") { ctx -> ctx.response.text(querySum(ctx) + bodyDigits(ctx)) }
    app.get("/pipeline") { ctx -> ctx.response.text(OK) }
    app.post("/echo") { ctx ->
        val request = ctx.request
        ctx.response.bytes(request.bodyBytes, request.bodyOffset, request.bodyLength)
    }
    app.get("/json/{count}") { ctx ->
        val state = json[ctx.reactor.id]
        val count = ctx.request.paramInt("count").coerceIn(0, state.items.size)
        val multiplier = ctx.request.queryLong(M, 1)
        for (i in 0 until count) {
            val item = state.items[i]
            item.total = item.price.toLong() * item.quantity * multiplier
        }
        state.window.size = count
        state.response.count = count
        ctx.response.json(state.response)
    }
    app.getAsync("/delay/{ms}") { ctx ->
        val ms = ctx.request.paramLong("ms", -1)
        if (ms < 0) {
            ctx.response.empty(404)
        } else {
            ctx.delay(ms)
            ctx.response.text(ms)
        }
    }

    println("[ktron-arena] $reactors reactors on :${app.options.port}" + (tls?.let { " + :${it.port} tls (kernel tx ${it.kernelTx})" } ?: "") +
        ", dataset=${dataset.size} items")
    app.run()
}

private class JsonState(dataset: List<DatasetItem>) {
    val items = Array(dataset.size) { i ->
        val it = dataset[i]
        Item(it.id, it.name, it.category, it.price, it.quantity, it.active, it.tags, it.rating, 0)
    }
    val window = Window(items)
    val response = JsonResponse(window, 0)
}

// Every value in the query added up, as /baseline11 answers.
private fun querySum(ctx: Context): Long {
    val request = ctx.request
    var sum = 0L
    for (i in 0 until request.queryCount) sum += request.queryLong(i, 0)
    return sum
}

// A body that is a decimal number: what is not a digit is not part of it.
private fun bodyDigits(ctx: Context): Long {
    val request = ctx.request
    val bytes = request.bodyBytes
    var value = 0L
    for (i in request.bodyOffset until request.bodyOffset + request.bodyLength) {
        val d = bytes[i] - '0'.code.toByte()
        if (d in 0..9) value = value * 10 + d
    }
    return value
}

private fun loadDataset(path: String): List<DatasetItem> = try {
    Ghost.deserialize<List<DatasetItem>>(File(path).readBytes())
} catch (e: Exception) {
    System.err.println("[ktron-arena] dataset load failed ($path): ${e.message}")
    emptyList()
}

private fun env(name: String): String? = System.getenv(name)?.takeIf { it.isNotBlank() }

private const val OK = "ok"
private val M = "m".toByteArray()
