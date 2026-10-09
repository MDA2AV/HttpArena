import kotlin.native.runtime.GC
import kotlin.native.runtime.NativeRuntimeApi
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout
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
import neton.database.dbContext
import neton.database.adapter.sqlx.SqlxDatabase
import neton.database.config.DatabaseConfig
import neton.database.config.DatabaseDriver
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import neton.http.http
import neton.http.static.staticFiles
import neton.core.http.adapter.TlsSettings
import neton.routing.*

/**
 * Neton's HTTP Arena entry. Engine.kt selects the transport; business routes are
 * identical in the neton and neton-hyper entries.
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
 * Not subscribed (see meta.json): the profiles that need capabilities the engine
 * does not have yet — HTTP/3, gRPC, WebSocket — and the multi-service DB profiles
 * (async-db, fortunes, production-stack). json-comp is served here: the framework
 * gzip-compresses compressible responses when the client sends Accept-Encoding.
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
// TLS listeners. 8081 serves the HTTP/1.1 + TLS profiles (json-tls, static-tls,
// 8gbit, tls); 8443 serves the HTTP/2 + TLS ones (baseline-h2, static-h2) via
// ALPN. Certificates are mounted read-only at /certs by the harness. Overridable
// so a dev machine need not hold the harness ports or certs.
private val H1TLS_PORT = getEnv("ARENA_H1TLS_PORT")?.toIntOrNull() ?: 8081
private val H2TLS_PORT = getEnv("ARENA_H2TLS_PORT")?.toIntOrNull() ?: 8443
private val CERT_PATH = getEnv("ARENA_CERT") ?: "/certs/server.crt"
private val KEY_PATH = getEnv("ARENA_KEY") ?: "/certs/server.key"
private val STATIC_DIR = getEnv("ARENA_STATIC") ?: "/data/static"
private val TLS_ENABLED = readConfigFile(CERT_PATH) != null && readConfigFile(KEY_PATH) != null

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
 * The floor is 1 GiB because the benchmark said so, and a smaller one was tried
 * and cost real throughput. At 128 local connections every floor from 64 MiB to
 * 1 GiB measured the same and resident memory simply tracked the floor, which
 * made 256 MiB look free; on the arena's 4096 connections it was not. Dropping
 * to 256 MiB cost 33% on latency-1m, 27% on pipelined and 19% on async — the
 * three profiles with the largest live set, which are exactly the ones that have
 * to spend part of a five-second run growing the heap back before they can go
 * fast. Autotune does climb past the floor here (baseline settles near 468 MiB,
 * baseline-h2c at 4096 connections near 1.5 GiB); it just cannot climb for free.
 *
 * Memory efficiency is a separate, optional dimension on the board. Throughput
 * is the ranking, so the floor is sized for throughput.
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
        http(::createEngine) {
            port = H1_PORT
        }

        // The Postgres pool (sqlx4k) stands up its own Rust/Tokio runtime; doing that
        // at startup made the DB-free profiles (baseline etc.) share the box with a
        // second multi-threaded runtime. Initialise it lazily on the first DB request
        // instead, so the plain profiles never pay for it. async-db/fortunes take a
        // one-time init on their first hit.

        routing {
            get("/baseline11") { it.writeSum() }
            post("/baseline11") { it.writeSum(withBody = true) }

            // The h2 shape of the same arithmetic, served on :8082.
            get("/baseline2") { it.writeSum() }

            get("/pipeline") { it.response.text("ok") }
            get("/delay/{ms}") { it.writeDelay() }
            get("/json/{count}") { it.writeItems(items) }

            // async-db: async Postgres sequential scan (no index on price) →
            // {count, items:[{..., active:bool, tags:[...], rating:{score,count}}]}.
            get("/async-db") { it.writeDbItems() }

            // fortunes: TechEmpower template benchmark — all fortune rows + one
            // runtime row, sorted by message, rendered as escaped HTML.
            get("/fortunes") { it.writeFortunes() }

            // 8gbit: read the posted body through the standard API and write it
            // back verbatim — not from Content-Length, so chunked echoes too.
            post("/echo") { it.echoBody() }

            // static-tls / static-h2: serve the mounted files with pre-compressed
            // .br/.gz variants selected off Accept-Encoding by the framework.
            staticFiles("/static", STATIC_DIR) { precompressed = true }
        }

        onReady {
            // Each listener is awaited to its bind before READY returns, so the
            // harness never probes a TLS port that is not up yet. A listener that
            // fails to bind fails the launch rather than leaving a silent gap.
            check(startListener(this, H2C_PORT, null)) { "h2c listener failed to bind on $H2C_PORT" }
            if (TLS_ENABLED) {
                check(startListener(this, H1TLS_PORT, TlsSettings(CERT_PATH, KEY_PATH, listOf("http/1.1")))) {
                    "h1+TLS listener failed to bind on $H1TLS_PORT"
                }
                check(startListener(this, H2TLS_PORT, TlsSettings(CERT_PATH, KEY_PATH, listOf("h2", "http/1.1")))) {
                    "h2+TLS listener failed to bind on $H2TLS_PORT"
                }
            }
        }
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
 * /async-db?min=&max=&limit=: rows from Postgres selected by price range. There is
 * no index on price, so this is a sequential scan — the point of the profile. The
 * body is built straight to bytes; `tags` is a JSONB column whose text is already a
 * valid JSON array, so it is embedded verbatim.
 */
private val dbMutex = Mutex()

@kotlin.concurrent.Volatile
private var dbReady = false

/** Lazily stand up the Postgres pool on the first DB request; idempotent. */
private suspend fun ensureDb() {
    if (dbReady) return
    dbMutex.withLock {
        if (dbReady) return
        SqlxDatabase.initialize(
            DatabaseConfig(
                driver = DatabaseDriver.POSTGRESQL,
                uri = "postgresql://bench:bench@localhost:5432/benchmark",
            ),
        )
        dbReady = true
    }
}

private suspend fun HttpContext.writeDbItems() {
    ensureDb()
    val min = request.queryParam("min")?.toIntOrNull() ?: 0
    val max = request.queryParam("max")?.toIntOrNull() ?: Int.MAX_VALUE
    val limit = (request.queryParam("limit")?.toIntOrNull() ?: 1).coerceIn(0, 1000)
    val rows = dbContext().fetchAll(
        "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count " +
            "FROM items WHERE price BETWEEN :min AND :max LIMIT :limit",
        mapOf("min" to min, "max" to max, "limit" to limit),
    )
    val sb = StringBuilder(64 + rows.size * 160)
    sb.append("{\"count\":").append(rows.size).append(",\"items\":[")
    for (i in rows.indices) {
        val r = rows[i]
        if (i > 0) sb.append(',')
        sb.append("{\"id\":").append(r.int("id"))
        sb.append(",\"name\":"); appendJsonString(sb, r.string("name"))
        sb.append(",\"category\":"); appendJsonString(sb, r.string("category"))
        sb.append(",\"price\":").append(r.int("price"))
        sb.append(",\"quantity\":").append(r.int("quantity"))
        sb.append(",\"active\":").append(r.boolean("active"))
        sb.append(",\"tags\":").append(r.string("tags"))
        sb.append(",\"rating\":{\"score\":").append(r.int("rating_score"))
        sb.append(",\"count\":").append(r.int("rating_count")).append("}}")
    }
    sb.append("]}")
    response.contentType = "application/json; charset=utf-8"
    response.write(sb.toString().encodeToByteArray())
}

/**
 * /fortunes: every row of the fortune table plus one row injected at request time,
 * sorted by message, rendered as an HTML table with each message HTML-escaped
 * (the seeded row 11 carries a raw <script> that must come out as &lt;script&gt;).
 */
private suspend fun HttpContext.writeFortunes() {
    ensureDb()
    val rows = dbContext().fetchAll("SELECT id, message FROM fortune", emptyMap())
    val fortunes = ArrayList<Pair<Int, String>>(rows.size + 1)
    for (r in rows) fortunes.add(r.int("id") to r.string("message"))
    fortunes.add(0 to "Additional fortune added at request time.")
    fortunes.sortBy { it.second }
    val sb = StringBuilder(24576)
    sb.append("<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table>")
    sb.append("<tr><th>id</th><th>message</th></tr>")
    for ((id, msg) in fortunes) {
        sb.append("<tr><td>").append(id).append("</td><td>")
        appendHtmlEscaped(sb, msg)
        sb.append("</td></tr>")
    }
    sb.append("</table></body></html>")
    response.contentType = "text/html; charset=utf-8"
    response.write(sb.toString().encodeToByteArray())
}

/** HTML-escape row text so user content cannot break out of the table cell. */
private fun appendHtmlEscaped(sb: StringBuilder, s: String) {
    for (c in s) when (c) {
        '<' -> sb.append("&lt;")
        '>' -> sb.append("&gt;")
        '&' -> sb.append("&amp;")
        '"' -> sb.append("&quot;")
        '\'' -> sb.append("&#39;")
        else -> sb.append(c)
    }
}

/** Minimal JSON string emitter for the DB text columns (name/category). */
private fun appendJsonString(sb: StringBuilder, value: String) {
    sb.append('"')
    for (c in value) {
        when {
            c == '"' -> sb.append("\\\"")
            c == '\\' -> sb.append("\\\\")
            c == '\n' -> sb.append("\\n")
            c == '\r' -> sb.append("\\r")
            c == '\t' -> sb.append("\\t")
            c.code < 0x20 -> sb.append("\\u").append(c.code.toString(16).padStart(4, '0'))
            else -> sb.append(c)
        }
    }
    sb.append('"')
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
/** /echo: hand back exactly the bytes that arrived. */
private suspend fun HttpContext.echoBody() {
    val body = request.body()
    response.contentType = "application/octet-stream"
    response.write(body)
}

/**
 * Brings up a TLS listener sharing the frozen route table. [alpn] is the server's
 * preference order: `["http/1.1"]` on 8081, `["h2","http/1.1"]` on 8443, so ALPN
 * chooses the protocol per connection.
 */
/**
 * Brings up one listener sharing the frozen route table and returns only once it
 * has bound (or failed). [tls] null serves cleartext; non-null terminates TLS
 * with the given ALPN. The serve loop runs for the process lifetime on its own
 * scope; this function returns as soon as the bind is confirmed so READY can gate
 * on every listener being up.
 */
private suspend fun startListener(
    application: KotlinApplication,
    port: Int,
    tls: TlsSettings?,
): Boolean {
    val context = application.get<NetonContext>()
    val adapter = createEngine(
        context.get(HttpServerConfig::class).copy(port = port, tls = tls),
    )
    val bound = CompletableDeferred<Unit>()
    CoroutineScope(SupervisorJob() + Dispatchers.Default).launch {
        try {
            adapter.start(context) { bound.complete(Unit) }
        } catch (e: Throwable) {
            bound.completeExceptionally(e)
        }
    }
    return try {
        withTimeout(10_000) { bound.await() }
        true
    } catch (_: Throwable) {
        false
    }
}
