package com.httparena

import io.ktor.http.*
import io.ktor.server.application.*
import io.ktor.server.engine.*
import io.ktor.server.netty.*
import io.ktor.server.plugins.compression.*
import io.ktor.server.plugins.defaultheaders.*
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import io.ktor.utils.io.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.ByteArrayOutputStream
import java.io.File
import java.sql.Connection
import java.sql.DriverManager
import java.util.zip.Deflater
import java.util.zip.GZIPOutputStream

@Serializable
data class DatasetItem(
    val id: Int,
    val name: String,
    val category: String,
    val price: Double,
    val quantity: Int,
    val active: Boolean,
    val tags: List<String>,
    val rating: RatingInfo
)

@Serializable
data class RatingInfo(
    val score: Double,
    val count: Int
)

@Serializable
data class ProcessedItem(
    val id: Int,
    val name: String,
    val category: String,
    val price: Double,
    val quantity: Int,
    val active: Boolean,
    val tags: List<String>,
    val rating: RatingInfo,
    val total: Double
)

@Serializable
data class JsonResponse(
    val items: List<ProcessedItem>,
    val count: Int
)

@Serializable
data class DbItem(
    val id: Int,
    val name: String,
    val category: String,
    val price: Double,
    val quantity: Int,
    val active: Boolean,
    val tags: List<String>,
    val rating: RatingInfo
)

@Serializable
data class DbResponse(
    val items: List<DbItem>,
    val count: Int
)

object AppData {
    val json = Json { ignoreUnknownKeys = true }
    var dataset: List<DatasetItem> = emptyList()
    var largeJsonCache: ByteArray = ByteArray(0)
    val staticFiles: MutableMap<String, Pair<ByteArray, String>> = mutableMapOf()
    var db: Connection? = null

    private val mimeTypes = mapOf(
        ".css" to "text/css",
        ".js" to "application/javascript",
        ".html" to "text/html",
        ".woff2" to "font/woff2",
        ".svg" to "image/svg+xml",
        ".webp" to "image/webp",
        ".json" to "application/json"
    )

    fun load() {
        // Dataset
        val path = System.getenv("DATASET_PATH") ?: "/data/dataset.json"
        val dataFile = File(path)
        if (dataFile.exists()) {
            dataset = json.decodeFromString<List<DatasetItem>>(dataFile.readText())
        }

        // Large dataset for compression
        val largeFile = File("/data/dataset-large.json")
        if (largeFile.exists()) {
            val largeItems = json.decodeFromString<List<DatasetItem>>(largeFile.readText())
            largeJsonCache = buildJsonCache(largeItems)
        }

        // Static files
        val staticDir = File("/data/static")
        if (staticDir.isDirectory) {
            staticDir.listFiles()?.forEach { file ->
                if (file.isFile) {
                    val ext = file.extension.let { if (it.isNotEmpty()) ".$it" else "" }
                    val ct = mimeTypes[ext] ?: "application/octet-stream"
                    staticFiles[file.name] = file.readBytes() to ct
                }
            }
        }

        // Database
        val dbFile = File("/data/benchmark.db")
        if (dbFile.exists()) {
            db = DriverManager.getConnection("jdbc:sqlite:file:/data/benchmark.db?mode=ro&immutable=1")
            db!!.createStatement().execute("PRAGMA mmap_size=268435456")
        }
    }

    private fun buildJsonCache(items: List<DatasetItem>): ByteArray {
        val processed = items.map { d ->
            ProcessedItem(
                id = d.id, name = d.name, category = d.category,
                price = d.price, quantity = d.quantity, active = d.active,
                tags = d.tags, rating = d.rating,
                total = Math.round(d.price * d.quantity * 100.0) / 100.0
            )
        }
        val resp = JsonResponse(items = processed, count = processed.size)
        return json.encodeToString(JsonResponse.serializer(), resp).toByteArray()
    }

    fun gzipCompress(data: ByteArray): ByteArray {
        val bos = ByteArrayOutputStream(data.size / 4)
        object : GZIPOutputStream(bos) {
            init { def.setLevel(Deflater.BEST_SPEED) }
        }.use { it.write(data) }
        return bos.toByteArray()
    }
}

fun main() {
    AppData.load()
    println("Ktor HttpArena server starting on :8080")

    embeddedServer(Netty, port = 8080, host = "0.0.0.0") {
        install(DefaultHeaders) {
            header("Server", "ktor")
        }

        routing {
            get("/pipeline") {
                call.respondText("ok", ContentType.Text.Plain)
            }

            get("/baseline11") {
                val sum = sumQueryParams(call)
                call.respondText(sum.toString(), ContentType.Text.Plain)
            }

            post("/baseline11") {
                var sum = sumQueryParams(call)
                val body = call.receiveText().trim()
                body.toLongOrNull()?.let { sum += it }
                call.respondText(sum.toString(), ContentType.Text.Plain)
            }

            get("/baseline2") {
                val sum = sumQueryParams(call)
                call.respondText(sum.toString(), ContentType.Text.Plain)
            }

            get("/json") {
                if (AppData.dataset.isEmpty()) {
                    call.respondText("Dataset not loaded", ContentType.Text.Plain, HttpStatusCode.InternalServerError)
                    return@get
                }
                val processed = AppData.dataset.map { d ->
                    ProcessedItem(
                        id = d.id, name = d.name, category = d.category,
                        price = d.price, quantity = d.quantity, active = d.active,
                        tags = d.tags, rating = d.rating,
                        total = Math.round(d.price * d.quantity * 100.0) / 100.0
                    )
                }
                val resp = JsonResponse(items = processed, count = processed.size)
                val body = AppData.json.encodeToString(JsonResponse.serializer(), resp).toByteArray()
                call.respondBytes(body, ContentType.Application.Json)
            }

            get("/compression") {
                if (AppData.largeJsonCache.isEmpty()) {
                    call.respondText("Dataset not loaded", ContentType.Text.Plain, HttpStatusCode.InternalServerError)
                    return@get
                }
                val acceptEncoding = call.request.header(HttpHeaders.AcceptEncoding) ?: ""
                if (acceptEncoding.contains("gzip")) {
                    call.response.header(HttpHeaders.ContentEncoding, "gzip")
                    call.respondBytes(AppData.gzipCompress(AppData.largeJsonCache), ContentType.Application.Json)
                } else {
                    call.respondBytes(AppData.largeJsonCache, ContentType.Application.Json)
                }
            }

            get("/db") {
                val conn = AppData.db
                if (conn == null) {
                    call.respondText("Database not available", ContentType.Text.Plain, HttpStatusCode.InternalServerError)
                    return@get
                }
                val min = call.parameters["min"]?.toDoubleOrNull() ?: 10.0
                val max = call.parameters["max"]?.toDoubleOrNull() ?: 50.0

                val items = mutableListOf<DbItem>()
                synchronized(conn) {
                    val stmt = conn.prepareStatement(
                        "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50"
                    )
                    stmt.setDouble(1, min)
                    stmt.setDouble(2, max)
                    val rs = stmt.executeQuery()
                    while (rs.next()) {
                        val tags = AppData.json.decodeFromString<List<String>>(rs.getString(7))
                        items.add(
                            DbItem(
                                id = rs.getInt(1),
                                name = rs.getString(2),
                                category = rs.getString(3),
                                price = rs.getDouble(4),
                                quantity = rs.getInt(5),
                                active = rs.getInt(6) == 1,
                                tags = tags,
                                rating = RatingInfo(score = rs.getDouble(8), count = rs.getInt(9))
                            )
                        )
                    }
                    rs.close()
                    stmt.close()
                }
                val resp = DbResponse(items = items, count = items.size)
                val body = AppData.json.encodeToString(DbResponse.serializer(), resp).toByteArray()
                call.respondBytes(body, ContentType.Application.Json)
            }

            post("/upload") {
                val channel = call.receiveChannel()
                var totalBytes = 0L
                val buf = ByteArray(65536)
                while (!channel.isClosedForRead) {
                    val read = channel.readAvailable(buf)
                    if (read > 0) totalBytes += read
                }
                call.respondText(totalBytes.toString(), ContentType.Text.Plain)
            }

            get("/static/{filename}") {
                val filename = call.parameters["filename"]
                if (filename == null) {
                    call.respond(HttpStatusCode.NotFound)
                    return@get
                }
                val entry = AppData.staticFiles[filename]
                if (entry == null) {
                    call.respond(HttpStatusCode.NotFound)
                    return@get
                }
                val (data, contentType) = entry
                call.respondBytes(data, ContentType.parse(contentType))
            }
        }
    }.start(wait = true)
}

private fun sumQueryParams(call: ApplicationCall): Long {
    var sum = 0L
    call.parameters.names().forEach { name ->
        call.parameters[name]?.toLongOrNull()?.let { sum += it }
    }
    return sum
}


