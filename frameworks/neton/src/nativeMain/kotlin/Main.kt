import kotlin.native.runtime.GC
import kotlin.native.runtime.NativeRuntimeApi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.io.encodeToSink
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.io.Buffer
import kotlinx.io.readByteArray
import neton.core.KotlinApplication
import neton.core.Neton
import neton.core.component.NetonContext
import neton.core.config.getEnv
import neton.core.config.readConfigFile
import neton.core.http.HttpContext
import neton.core.http.HttpStatus
import neton.core.http.adapter.HttpServerConfig
import neton.http.http
import neton.http.hyper4k.Hyper4kHttpAdapter
import neton.routing.*

/**
 * Neton's HTTP Arena entry: a Kotlin/Native executable on the hyper4k engine
 * (Tokio + Hyper 1.x, linked in as a Rust static library).
 *
 * The arena diffs response bytes, so every handler commits through HttpResponse
 * directly. A committed response is written out verbatim — the dispatcher only
 * wraps a handler's *return value* in its {"code":0,"message":"OK","data":…}
 * envelope, and there is nothing left to wrap once the body is on the wire.
 *
 * Two listeners share one route table: :8080 for the HTTP/1.1 profiles and
 * :8082 for the h2c ones. hyper4k answers HTTP/1.1 and HTTP/2 cleartext on the
 * same socket by prior knowledge, so the second listener is a second adapter
 * over the same frozen context, not a second application.
 *
 * Not subscribed (see meta.json): the TLS profiles — the engine terminates no
 * TLS today — plus json-comp, which needs gzip/br response compression.
 */

/**
 * Arena port map: 8080 HTTP/1.1, 8082 HTTP/2 cleartext (prior knowledge).
 * Both are fixed by the harness (`scripts/lib/common.sh`), which runs containers
 * on the host network and points its load generators at those numbers.
 *
 * The h1 port already came from application.conf; ARENA_H2C_PORT gives the second
 * listener the same treatment, so running the entry on a developer machine does not
 * have to occupy the harness ports. The harness sets neither.
 */
private const val H1_PORT = 8080
private val H2C_PORT = getEnv("ARENA_H2C_PORT")?.toIntOrNull() ?: 8082

/**
 * Mounted read-only by the harness: -v data/dataset.json:/data/dataset.json:ro.
 *
 * ARENA_DATASET overrides it so the entry can be run outside the container,
 * where `/data` is not creatable on a developer machine; the harness sets no
 * such variable, so measured runs always read the mount.
 */
private val DATASET_PATH = getEnv("ARENA_DATASET") ?: "/data/dataset.json"

/**
 * Kotlin/Native starts with a 10 MiB target heap and a 5 MiB floor. Autotune
 * raises the target under load, but from that floor it collects constantly on a
 * workload that allocates per request, and the mutators spend their time parked
 * on the collector's locks rather than serving. Profiles of this entry are
 * dominated by `safePointActionImpl` and by threads blocked in
 * `pthread_mutex_lock`, which is what that looks like from the outside.
 *
 * Giving the floor real room trades memory the box has (251 GiB) for collections
 * it does not need to run. Autotune stays on so the target still follows the
 * live set upward.
 */
@OptIn(NativeRuntimeApi::class)
private fun tuneGc() {
    GC.minHeapBytes = 1L * 1024 * 1024 * 1024
    GC.targetHeapBytes = 2L * 1024 * 1024 * 1024
}

fun main(args: Array<String>) {
    tuneGc()
    val items = ArenaItems.load(DATASET_PATH)

    Neton.run(args) {
        http {
            port = H1_PORT
        }

        routing {
            get("/baseline11") { it.writeSum() }
            post("/baseline11") { it.writeSum(withBody = true) }

            // The h2 shape of the same arithmetic, served on :8082.
            get("/baseline2") { it.writeSum() }

            get("/pipeline") { it.response.text("ok") }
            get("/delay/{ms}") { it.writeDelay() }
            get("/json/{count}") { it.writeItems(items) }
        }

        onReady { startH2cListener(this) }
    }
}

/**
 * /baseline11 and /baseline2: the sum of the two query parameters, plus the
 * request body when there is one. Plain text, no envelope, no trailing newline.
 */
private suspend fun HttpContext.writeSum(withBody: Boolean = false) {
    val a = request.queryParam("a")?.toIntOrNull() ?: 0
    val b = request.queryParam("b")?.toIntOrNull() ?: 0
    val body = if (withBody) request.text().trim().toIntOrNull() ?: 0 else 0
    response.text((a + b + body).toString())
}

/**
 * /delay/{ms}: wait the requested milliseconds, then echo the parameter back.
 *
 * The wait is per request, so overlapping requests each carry their own timer —
 * the arena fires 32 concurrent delays and diffs every one of them against the
 * value it asked for.
 */
private suspend fun HttpContext.writeDelay() {
    val raw = request.pathParam("ms") ?: "0"
    val millis = raw.toLongOrNull()
    if (millis == null || millis < 0) {
        response.status = HttpStatus.BAD_REQUEST
        response.text("invalid delay: $raw")
        return
    }
    // 0 is a valid delay, not a missing one: it answers immediately.
    if (millis > 0) delay(millis)
    response.text(raw)
}

/** /json/{count}?m=M: the first `count` dataset items, each carrying its total. */
private suspend fun HttpContext.writeItems(items: ArenaItems) {
    // The bytes are what goes on the wire, so build them directly. Going through
    // `response.json(String)` would serialize into a String and then encode that
    // String to UTF-8 — a second full pass over the payload for nothing.
    response.contentType = "application/json; charset=utf-8"
    response.write(items.render(request.pathParam("count"), request.queryParam("m")))
}

/**
 * The dataset behind `/json/{count}?m=M`: the first `count` items of
 * /data/dataset.json, field for field, each with total = price * quantity * m.
 *
 * The dataset is parsed into typed items once at startup, because it is static
 * input, not a response. Every request then builds its own item list and runs it
 * through kotlinx.serialization. The profile exists to measure that work, and the
 * rules say so: pre-computed or pre-serialized response bodies are not allowed on
 * either entry type, because they short-circuit exactly what is being measured.
 */
@Serializable
private class Rating(val score: Int, val count: Int)

@Serializable
private class RenderedItem(
    val id: Int,
    val name: String,
    val category: String,
    val price: Int,
    val quantity: Int,
    val active: Boolean,
    val tags: List<String>,
    val rating: Rating,
    val total: Long,
)

@Serializable
private class ItemsResponse(val count: Int, val items: List<RenderedItem>)

/** One dataset row, parsed once. `total` is per request and lives nowhere here. */
private class SourceItem(
    val id: Int,
    val name: String,
    val category: String,
    val price: Int,
    val quantity: Int,
    val active: Boolean,
    val tags: List<String>,
    val rating: Rating,
)

private class ArenaItems(private val source: List<SourceItem>) {
    val size: Int get() = source.size

    private val json = Json { encodeDefaults = true }

    fun render(count: String?, multiplier: String?): ByteArray {
        val m = multiplier?.toLongOrNull() ?: 1L
        val n = (count?.toIntOrNull() ?: 0).coerceIn(0, size)
        val items = ArrayList<RenderedItem>(n)
        for (i in 0 until n) {
            val row = source[i]
            items.add(
                RenderedItem(
                    id = row.id,
                    name = row.name,
                    category = row.category,
                    price = row.price,
                    quantity = row.quantity,
                    active = row.active,
                    tags = row.tags,
                    rating = row.rating,
                    total = row.price.toLong() * row.quantity.toLong() * m,
                ),
            )
        }
        val buffer = Buffer()
        json.encodeToSink(ItemsResponse.serializer(), ItemsResponse(n, items), buffer)
        return buffer.readByteArray()
    }

    companion object {
        fun load(path: String): ArenaItems {
            // neton-core's cross-platform reader — the same call the config
            // loader makes, so the entry needs no platform-specific IO of its
            // own. Missing dataset is fatal on purpose: an empty item list
            // would answer every request with a well-formed wrong response.
            val text = readConfigFile(path) ?: error("dataset not readable at $path")
            val rows = Json.parseToJsonElement(text).jsonArray.map { element ->
                val o = element.jsonObject
                val rating = o["rating"]?.jsonObject
                SourceItem(
                    id = o["id"]?.jsonPrimitive?.int ?: 0,
                    name = o["name"]?.jsonPrimitive?.content ?: "",
                    category = o["category"]?.jsonPrimitive?.content ?: "",
                    price = o["price"]?.jsonPrimitive?.int ?: 0,
                    quantity = o["quantity"]?.jsonPrimitive?.int ?: 0,
                    active = o["active"]?.jsonPrimitive?.boolean ?: false,
                    tags = o["tags"]?.jsonArray?.map { it.jsonPrimitive.content } ?: emptyList(),
                    rating = Rating(
                        score = rating?.get("score")?.jsonPrimitive?.int ?: 0,
                        count = rating?.get("count")?.jsonPrimitive?.int ?: 0,
                    ),
                )
            }
            return ArenaItems(rows)
        }
    }
}

/**
 * Bring up :8082 once the primary listener is confirmed listening.
 *
 * Same frozen context, so both listeners serve an identical route table and
 * hyper4k negotiates HTTP/1.1 or HTTP/2 per connection on either of them.
 */
private fun startH2cListener(application: KotlinApplication) {
    val context = application.get<NetonContext>()
    // Copy the config the framework already resolved from application.conf and
    // change only the port. Spelling the fields out again here meant the h2c
    // listener silently ignored the file: the h1 listener ran with the
    // configured timeout and connection ceiling while this one kept whatever
    // was hard-coded, so the two listeners were never the same server and no
    // config-level experiment could reach the h2c profiles.
    val adapter = Hyper4kHttpAdapter(
        context.get(HttpServerConfig::class).copy(port = H2C_PORT),
    )
    // start() holds the listener open for the process lifetime and never
    // returns, so it cannot run on the framework's own start path.
    CoroutineScope(SupervisorJob() + Dispatchers.Default).launch {
        adapter.start(context, null)
    }
}
