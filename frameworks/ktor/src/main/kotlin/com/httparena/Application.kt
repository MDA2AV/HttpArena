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
import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import java.io.File
import java.net.URI
import java.sql.Connection
import java.sql.DriverManager

@Serializable
data class DatasetItem(
    val id: Int,
    val name: String,
    val category: String,
    val price: Int,
    val quantity: Int,
    val active: Boolean,
    val tags: List<String>,
    val rating: RatingInfo
)

@Serializable
data class RatingInfo(
    val score: Int,
    val count: Int
)

@Serializable
data class ProcessedItem(
    val id: Int,
    val name: String,
    val category: String,
    val price: Int,
    val quantity: Int,
    val active: Boolean,
    val tags: List<String>,
    val rating: RatingInfo,
    val total: Long
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
    val price: Int,
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
    data class StaticEntry(val data: ByteArray, val br: ByteArray?, val gz: ByteArray?, val contentType: String)
    val staticFiles: MutableMap<String, StaticEntry> = mutableMapOf()
    var db: Connection? = null
    var pgPool: HikariDataSource? = null

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

        // Static files with pre-compressed variants
        val staticDir = File("/data/static")
        if (staticDir.isDirectory) {
            staticDir.listFiles()?.forEach { file ->
                if (file.isFile && !file.name.endsWith(".br") && !file.name.endsWith(".gz")) {
                    val ext = file.extension.let { if (it.isNotEmpty()) ".$it" else "" }
                    val ct = mimeTypes[ext] ?: "application/octet-stream"
                    val brFile = File(file.path + ".br")
                    val gzFile = File(file.path + ".gz")
                    staticFiles[file.name] = StaticEntry(
                        data = file.readBytes(),
                        br = if (brFile.exists()) brFile.readBytes() else null,
                        gz = if (gzFile.exists()) gzFile.readBytes() else null,
                        contentType = ct
                    )
                }
            }
        }

        // Database
        val dbFile = File("/data/benchmark.db")
        if (dbFile.exists()) {
            db = DriverManager.getConnection("jdbc:sqlite:file:/data/benchmark.db?mode=ro&immutable=1")
            db!!.createStatement().execute("PRAGMA mmap_size=268435456")
        }

        // PostgreSQL connection pool
        val dbUrl = System.getenv("DATABASE_URL")
        if (!dbUrl.isNullOrEmpty()) {
            try {
                val uri = URI(dbUrl.replace("postgres://", "postgresql://"))
                val host = uri.host
                val port = if (uri.port > 0) uri.port else 5432
                val database = uri.path.removePrefix("/")
                val userInfo = uri.userInfo.split(":")
                val config = HikariConfig()
                config.driverClassName = "org.postgresql.Driver"
                config.jdbcUrl = "jdbc:postgresql://$host:$port/$database"
                config.username = userInfo[0]
                config.password = if (userInfo.size > 1) userInfo[1] else ""
                config.maximumPoolSize = 64
                config.minimumIdle = 16
                pgPool = HikariDataSource(config)
            } catch (e: Exception) {
                System.err.println("PG pool init failed: $e")
            }
        }
    }

}

fun main() {
    AppData.load()
    println("Ktor HttpArena server starting on :8080")

    embeddedServer(Netty, port = 8080, host = "0.0.0.0") {
        install(DefaultHeaders) {
            header("Server", "ktor")
        }
        install(Compression)

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

            get("/json/{count}") {
                if (AppData.dataset.isEmpty()) {
                    call.respondText("Dataset not loaded", ContentType.Text.Plain, HttpStatusCode.InternalServerError)
                    return@get
                }
                var count = call.parameters["count"]?.toIntOrNull() ?: 0
                if (count < 0) count = 0
                if (count > AppData.dataset.size) count = AppData.dataset.size
                val m = call.request.queryParameters["m"]?.toIntOrNull() ?: 1
                val processed = AppData.dataset.take(count).map { d ->
                    ProcessedItem(
                        id = d.id, name = d.name, category = d.category,
                        price = d.price, quantity = d.quantity, active = d.active,
                        tags = d.tags, rating = d.rating,
                        total = d.price.toLong() * d.quantity * m
                    )
                }
                val resp = JsonResponse(items = processed, count = count)
                val body = AppData.json.encodeToString(JsonResponse.serializer(), resp).toByteArray()
                call.respondBytes(body, ContentType.Application.Json)
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
                                price = rs.getInt(4),
                                quantity = rs.getInt(5),
                                active = rs.getInt(6) == 1,
                                tags = tags,
                                rating = RatingInfo(score = rs.getInt(8), count = rs.getInt(9))
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

            get("/async-db") {
                val pool = AppData.pgPool
                if (pool == null) {
                    call.respondBytes("{\"items\":[],\"count\":0}".toByteArray(), ContentType.Application.Json)
                    return@get
                }
                val min = call.request.queryParameters["min"]?.toIntOrNull() ?: 10
                val max = call.request.queryParameters["max"]?.toIntOrNull() ?: 50
                val limit = (call.request.queryParameters["limit"]?.toIntOrNull() ?: 50).coerceIn(1, 50)
                try {
                    val items = mutableListOf<DbItem>()
                    pool.connection.use { conn ->
                        val stmt = conn.prepareStatement(
                            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT ?"
                        )
                        stmt.setInt(1, min)
                        stmt.setInt(2, max)
                        stmt.setInt(3, limit)
                        val rs = stmt.executeQuery()
                        while (rs.next()) {
                            val tags = AppData.json.decodeFromString<List<String>>(rs.getString(7))
                            items.add(
                                DbItem(
                                    id = rs.getInt(1),
                                    name = rs.getString(2),
                                    category = rs.getString(3),
                                    price = rs.getInt(4),
                                    quantity = rs.getInt(5),
                                    active = rs.getBoolean(6),
                                    tags = tags,
                                    rating = RatingInfo(score = rs.getInt(8), count = rs.getInt(9))
                                )
                            )
                        }
                        rs.close()
                        stmt.close()
                    }
                    val resp = DbResponse(items = items, count = items.size)
                    val body = AppData.json.encodeToString(DbResponse.serializer(), resp).toByteArray()
                    call.respondBytes(body, ContentType.Application.Json)
                } catch (_: Exception) {
                    call.respondBytes("{\"items\":[],\"count\":0}".toByteArray(), ContentType.Application.Json)
                }
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
                val ae = call.request.header(HttpHeaders.AcceptEncoding) ?: ""
                if (entry.br != null && ae.contains("br")) {
                    call.response.header(HttpHeaders.ContentEncoding, "br")
                    call.respondBytes(entry.br, ContentType.parse(entry.contentType))
                } else if (entry.gz != null && ae.contains("gzip")) {
                    call.response.header(HttpHeaders.ContentEncoding, "gzip")
                    call.respondBytes(entry.gz, ContentType.parse(entry.contentType))
                } else {
                    call.respondBytes(entry.data, ContentType.parse(entry.contentType))
                }
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


