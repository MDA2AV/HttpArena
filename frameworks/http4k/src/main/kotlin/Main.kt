import io.undertow.UndertowOptions
import java.io.File
import java.io.FileInputStream
import java.security.KeyFactory
import java.security.KeyStore
import java.security.cert.Certificate
import java.security.cert.CertificateFactory
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Base64
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import org.http4k.core.ContentType
import org.http4k.core.Method
import org.http4k.core.Request
import org.http4k.core.Response
import org.http4k.core.Status.Companion.OK
import org.http4k.core.queries
import org.http4k.core.then
import org.http4k.filter.ServerFilters
import org.http4k.format.Jackson
import org.http4k.routing.bind
import org.http4k.routing.path
import org.http4k.routing.routes
import org.http4k.server.ServerConfig.StopMode.Immediate
import org.http4k.server.buildHttp4kUndertowServer
import org.http4k.server.buildUndertowHandlers

data class Rating(val score: Long, val count: Long)

data class DatasetItem(
    val id: Long,
    val name: String,
    val category: String,
    val price: Long,
    val quantity: Long,
    val active: Boolean,
    val tags: List<String>,
    val rating: Rating
)

data class ProcessedItem(
    val id: Long,
    val name: String,
    val category: String,
    val price: Long,
    val quantity: Long,
    val active: Boolean,
    val tags: List<String>,
    val rating: Rating,
    val total: Long
)

data class ProcessResponse(val items: List<ProcessedItem>, val count: Int)

val dataset: List<DatasetItem> = try {
    // read as an array: a List type argument would be erased and give back maps
    Jackson.asA(
        File(System.getenv("DATASET_PATH") ?: "/data/dataset.json").readText(),
        Array<DatasetItem>::class
    ).toList()
} catch (e: Exception) {
    emptyList()
}

fun text(body: String) = Response(OK).header("Content-Type", "text/plain").body(body)

fun baseline11(request: Request): Response {
    var sum = request.uri.queries().sumOf { it.second?.trim()?.toLongOrNull() ?: 0L }
    if (request.method == Method.POST) {
        sum += request.bodyString().trim().toLongOrNull() ?: 0L
    }
    return text(sum.toString())
}

fun jsonItems(request: Request): Response {
    val count = (request.path("count")?.toIntOrNull() ?: 0).coerceIn(0, dataset.size)
    val m = request.query("m")?.toLongOrNull() ?: 1L

    val items = dataset.take(count).map {
        ProcessedItem(
            id = it.id,
            name = it.name,
            category = it.category,
            price = it.price,
            quantity = it.quantity,
            active = it.active,
            tags = it.tags,
            rating = it.rating,
            total = it.price * it.quantity * m
        )
    }
    return Response(OK)
        .header("Content-Type", ContentType.APPLICATION_JSON.value)
        .body(Jackson.asFormatString(ProcessResponse(items, items.size)))
}

fun upload(request: Request): Response {
    var size = 0L
    val buffer = ByteArray(64 * 1024)
    request.body.stream.use { stream ->
        while (true) {
            val read = stream.read(buffer)
            if (read < 0) break
            size += read
        }
    }
    return text(size.toString())
}

val app = routes(
    "/pipeline" bind Method.GET to { _: Request -> text("ok") },
    "/baseline11" bind Method.GET to ::baseline11,
    "/baseline11" bind Method.POST to ::baseline11,
    "/json/{count}" bind Method.GET to ::jsonItems,
    "/upload" bind Method.POST to ::upload
)

// json-tls needs HTTP/1.1 over TLS on 8081. Undertow takes an SSLContext, and
// the harness mounts PEMs, so the pair is converted in-process. Plain JDK
// crypto APIs rather than java.security.PEMDecoder, which is still a preview
// API on this JDK. Null when the certs are absent -- the harness only mounts
// them for the TLS profiles.
fun tlsContext(): SSLContext? {
    val cert = File("/certs/server.crt")
    val key = File("/certs/server.key")
    if (!cert.exists() || !key.exists()) return null

    val chain: Array<Certificate> = FileInputStream(cert).use {
        CertificateFactory.getInstance("X.509").generateCertificates(it).toTypedArray()
    }
    val der = Base64.getDecoder().decode(
        key.readText()
            .replace(Regex("-----(BEGIN|END) PRIVATE KEY-----"), "")
            .replace(Regex("\\s"), "")
    )
    val privateKey = KeyFactory.getInstance("RSA").generatePrivate(PKCS8EncodedKeySpec(der))
    val password = CharArray(0)
    val store = KeyStore.getInstance("PKCS12").apply {
        load(null, password)
        setKeyEntry("server", privateKey, password, chain)
    }
    val keyManagers = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        .apply { init(store, password) }
        .keyManagers

    return SSLContext.getInstance("TLS").apply { init(keyManagers, null, null) }
}

fun main() {
    // The stock http4k Undertow config caps requests at 10 MB and the upload
    // profile sends 20 MB, so the same server is built with a larger limit, the
    // way the http4k Undertow source suggests.
    val handler = ServerFilters.GZip().then(app)
    val (httpHandler, rootHandler) = buildUndertowHandlers(handler, null, null, Immediate)

    val builder = io.undertow.Undertow.builder()
        .addHttpListener(8080, "0.0.0.0")
        .setServerOption(UndertowOptions.MAX_ENTITY_SIZE, 30L * 1024 * 1024)
        .setWorkerThreads(32 * Runtime.getRuntime().availableProcessors())
        .setHandler(rootHandler)

    // Same builder, so 8081 runs the identical handler chain as 8080.
    tlsContext()?.let { builder.addHttpsListener(8081, "0.0.0.0", it) }

    builder
        .buildHttp4kUndertowServer(httpHandler, Immediate, 8080)
        .start()
}
