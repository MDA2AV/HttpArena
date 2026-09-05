import kotlin.native.runtime.GC
import kotlin.native.runtime.NativeRuntimeApi
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
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
    response.json(items.render(request.pathParam("count"), request.queryParam("m")))
}

/**
 * The dataset behind /json/{count}?m=M: the first `count` items of
 * /data/dataset.json, field-for-field unchanged, each with
 * total = price * quantity * m added.
 *
 * Parsed once at startup and kept as the JSON text that *precedes* each total,
 * so serving a request appends one number per item and re-serializes nothing.
 * Keeping the original literals is also what keeps integers integers: round
 * tripping through a typed model would risk 328 becoming 328.0.
 */
private class ArenaItems(
    val size: Int,
    private val beforeTotal: List<String>,
    private val priceTimesQuantity: IntArray,
) {
    fun render(count: String?, multiplier: String?): String {
        val m = multiplier?.toLongOrNull() ?: 1L
        val wanted = count?.toIntOrNull() ?: 0
        val n = wanted.coerceIn(0, size)
        val out = StringBuilder(n * 128 + 32)
        out.append("{\"count\":").append(n).append(",\"items\":[")
        for (i in 0 until n) {
            if (i > 0) out.append(',')
            out.append(beforeTotal[i]).append(priceTimesQuantity[i] * m).append('}')
        }
        return out.append("]}").toString()
    }

    companion object {
        fun load(path: String): ArenaItems {
            // neton-core's cross-platform reader — the same call the config
            // loader makes, so the entry needs no platform-specific IO of its
            // own. Missing dataset is fatal on purpose: an empty item list
            // would answer every request with a well-formed wrong response.
            val text = readConfigFile(path) ?: error("dataset not readable at $path")
            val beforeTotal = mutableListOf<String>()
            val priceTimesQuantity = mutableListOf<Int>()
            for (element in Json.parseToJsonElement(text).jsonArray) {
                val item = element.jsonObject
                val price = item["price"]?.jsonPrimitive?.int ?: 0
                val quantity = item["quantity"]?.jsonPrimitive?.int ?: 0
                // Drop an incoming total so the one appended per request is the
                // only one, whatever the mounted dataset happens to carry.
                val withoutTotal = JsonObject(item.filterKeys { it != "total" })
                beforeTotal.add(withoutTotal.toString().dropLast(1) + ",\"total\":")
                priceTimesQuantity.add(price * quantity)
            }
            return ArenaItems(beforeTotal.size, beforeTotal, priceTimesQuantity.toIntArray())
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
