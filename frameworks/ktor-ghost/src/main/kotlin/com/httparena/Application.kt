package com.httparena

import com.httparena.DbResponse.Companion.toResponse
import io.ktor.http.*
import io.ktor.http.content.*
import com.ghost.serialization.Ghost
import io.ktor.http.content.ByteArrayContent
import io.ktor.server.request.receive
import io.ktor.server.application.*
import io.ktor.server.engine.*
import io.ktor.server.html.*
import io.ktor.server.http.content.*
import io.ktor.server.netty.*
import io.ktor.server.plugins.compression.*
import io.ktor.server.plugins.contentnegotiation.*
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import io.ktor.server.websocket.*
import io.ktor.utils.io.*
import io.netty.channel.ChannelOption
import io.netty.channel.WriteBufferWaterMark
import io.netty.handler.flush.FlushConsolidationHandler
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.html.*
import org.jetbrains.exposed.v1.core.SortOrder
import org.jetbrains.exposed.v1.core.between
import org.jetbrains.exposed.v1.core.eq
import org.jetbrains.exposed.v1.jdbc.selectAll
import org.jetbrains.exposed.v1.jdbc.transactions.transaction
import org.jetbrains.exposed.v1.jdbc.update
import org.jetbrains.exposed.v1.jdbc.upsert
import org.slf4j.Logger
import org.slf4j.LoggerFactory
import java.io.File

fun main() {
    Ghost.prewarm()
    println("Ktor HttpArena server starting on :8080 (HTTP/1.1) and :8443 (HTTPS/HTTP+2)")
    val deps = ArenaApplicationDepsFactory.load()
    val environment = applicationEnvironment {}

    val server = embeddedServer(Netty, environment, {
        enableHttp2 = true

        connector {
            port = 8080
            host = "0.0.0.0"
        }
        deps.keyStore?.let { keyStore ->
            sslConnector(
                keyStore = keyStore,
                keyAlias = KEY_ALIAS,
                keyStorePassword = { KEYSTORE_PASSWORD },
                privateKeyPassword = { KEYSTORE_PASSWORD }
            ) {
                port = 8081
                host = "0.0.0.0"
            }
            sslConnector(
                keyStore = keyStore,
                keyAlias = KEY_ALIAS,
                keyStorePassword = { KEYSTORE_PASSWORD },
                privateKeyPassword = { KEYSTORE_PASSWORD }
            ) {
                port = 8443
                host = "0.0.0.0"
            }
        }
    }) {
        mainModule(deps)
    }

    // Spin up a second server for H2C
    embeddedServer(Netty, environment, {
        enableH2c = true

        connector {
            port = 8082
            host = "0.0.0.0"
        }
    }) {
        // Reject any non-HTTP/2 request hitting the H2C connector
        intercept(ApplicationCallPipeline.Plugins) {
            val version = call.request.httpVersion
            if (!version.startsWith("HTTP/2")) {
                call.response.headers.append(HttpHeaders.Upgrade, "h2c")
                call.response.headers.append(HttpHeaders.Connection, "Upgrade")
                call.respond(HttpStatusCode.UpgradeRequired, "HTTP/2 (h2c) required")
                finish()
                return@intercept
            }
        }
        // Import the same endpoints for this server
        mainModule(deps)

    }.start(wait = false)

    server.start(wait = true)
}

internal fun Application.mainModule(appData: ArenaApplicationDeps) {
    install(WebSockets)

    configureRouting(appData)
}

private fun Application.configureRouting(appData: ArenaApplicationDeps) {
    val pipelineResponse = ByteArrayContent("ok".toByteArray(), ContentType.Text.Plain)

    fun ApplicationCall.sumQueryParams(): Long {
        var start = 0
        var sum = 0L
        for (i in request.uri.indices) {
            when(request.uri[i]) {
                '=' -> {
                    start = i + 1
                }
                '&' -> {
                    val v = request.uri.substring(start, i)
                    sum += v.toLongOrNull() ?: 0
                }
            }
        }
        return sum + (request.uri.substring(start).toLongOrNull() ?: 0)
    }

    suspend fun ApplicationCall.respondNumber(long: Long) =
        respond(TextContent(long.toString(), ContentType.Text.Plain))

    routing {
        /**
         * Pipelined
         * https://www.http-arena.com/docs/test-profiles/h1/isolated/pipelined/
         */
        get("/pipeline") {
            call.respond(pipelineResponse)
        }

        /**
         * Baseline 1.1
         * https://www.http-arena.com/docs/test-profiles/h1/isolated/baseline/
         */
        get("/baseline11") {
            call.respondNumber(call.sumQueryParams())
        }

        /**
         * Baseline 1.1
         * https://www.http-arena.com/docs/test-profiles/h1/isolated/baseline/
         */
        post("/baseline11") {
            val sum = call.sumQueryParams()
            val body = call.receiveText().trim().toLongOrNull() ?: run {
                call.respondText(sum.toString(), ContentType.Text.Plain)
                return@post
            }
            call.respondNumber(sum + body)
        }

        /**
         * Baseline 2
         * https://www.http-arena.com/docs/test-profiles/h1/isolated/baseline/
         */
        get("/baseline2") {
            call.respondNumber(call.sumQueryParams())
        }

        /**
         * JSON processing
         * https://www.http-arena.com/docs/test-profiles/h1/isolated/json-processing/
         * https://www.http-arena.com/docs/test-profiles/h1/isolated/json-tls/
         * https://www.http-arena.com/docs/test-profiles/h1/isolated/json-compressed/
         */
        route("/json/{count}") {
            install(Compression) {
                gzip()
            }
            get {
                if (appData.dataset.isEmpty()) {
                    call.respondText("Dataset not loaded", ContentType.Text.Plain, HttpStatusCode.InternalServerError)
                    return@get
                }
                var count = call.pathParameters["count"]?.toIntOrNull() ?: 0
                if (count < 0) count = 0
                if (count > appData.dataset.size) count = appData.dataset.size
                val m = call.request.queryParameters["m"]?.toIntOrNull() ?: 1
                val processed = appData.dataset.take(count).map { d ->
                    ProcessedItem(
                        id = d.id, name = d.name, category = d.category,
                        price = d.price, quantity = d.quantity, active = d.active,
                        tags = d.tags, rating = d.rating,
                        total = d.price.toLong() * d.quantity * m
                    )
                }
                call.respondGhost(JsonResponse(items = processed, count = count))
            }
        }

        /**
         * Async DB
         * https://www.http-arena.com/docs/test-profiles/h1/isolated/async-database/
         */
        route("/async-db") {
            get {
                val min = call.request.queryParameters["min"]?.toIntOrNull() ?: 10
                val max = call.request.queryParameters["max"]?.toIntOrNull() ?: 50
                val limit = (call.request.queryParameters["limit"]?.toIntOrNull() ?: 50).coerceIn(1, 50)
                try {
                    val items = withContext(Dispatchers.IO) {
                        transaction(appData.postgres, readOnly = true) {
                            with(ItemTable) {
                                selectAll()
                                    .where { price.between(min, max) }
                                    .limit(limit)
                                    .map(::toDbItem)
                            }
                        }
                    }
                    call.respondGhost(items.toResponse())
                } catch (e: Exception) {
                    log.error("Failed to load items from DB", e)
                    call.respondText("{\"items\":[],\"count\":0}", ContentType.Application.Json)
                }
            }
        }

        /**
         * Upload 20MB
         * https://www.http-arena.com/docs/test-profiles/h1/isolated/upload/
         */
        post("/upload") {
            val channel = call.request.receiveChannel()
            val totalBytes = channel.readTo(DevNull)
            call.respondText(
                totalBytes.toString(),
                ContentType.Text.Plain
            )
        }

        /**
         * Static files
         * https://www.http-arena.com/docs/test-profiles/h1/isolated/static/
         */
        staticFiles("/static", File("/data/static")) {
            preCompressed(CompressedFileType.BROTLI, CompressedFileType.GZIP)
        }

        /**
         * Echo WebSocket
         * https://www.http-arena.com/docs/test-profiles/ws/
         */
        webSocket("/ws") {
            for (message in incoming)
                send(message)
        }

        /**
         * CRUD (REST API) — paginated list, cached single-item read, upsert create, partial update.
         * https://www.http-arena.com/docs/test-profiles/h1/isolated/crud/
         */
        crudEndpoints(appData)

        /**
         * Fortunes (template-engine benchmark) — kotlinx.html DSL.
         * https://www.http-arena.com/docs/test-profiles/h1/isolated/fortunes/
         */
        get("/fortunes") {
            val fortunes = mutableListOf<Fortune>()
            try {
                withContext(Dispatchers.IO) {
                    transaction(appData.postgres, readOnly = true) {
                        FortuneTable.selectAll()
                            .map(FortuneTable::toFortune)
                            .toCollection(fortunes)
                    }
                }
            } catch (e: Exception) {
                log.error("Failed to load fortunes from DB", e)
                call.respond(HttpStatusCode.InternalServerError, "fortunes failed")
                return@get
            }
            fortunes.add(RUNTIME_FORTUNE)
            fortunes.sortBy { it.message }

            call.respondHtml(HttpStatusCode.OK) {
                head { title { +"Fortunes" } }
                body {
                    table {
                        tr {
                            th { +"id" }
                            th { +"message" }
                        }
                        for ((id, message) in fortunes) {
                            tr {
                                td { +id.toString() }
                                td { +message }
                            }
                        }
                    }
                }
            }
        }

    }
}

suspend inline fun <reified T : Any> ApplicationCall.respondGhost(
    value: T,
    status: HttpStatusCode = HttpStatusCode.OK
) {
    val bytes = Ghost.encodeToBytes(value)
    respond(ByteArrayContent(bytes, ContentType.Application.Json, status))
}

suspend inline fun <reified T : Any> ApplicationCall.respondGhost(
    status: HttpStatusCode,
    value: T
) {
    respondGhost(value, status)
}

suspend inline fun <reified T : Any> ApplicationCall.receiveGhost(): T {
    val bytes = receive<ByteArray>()
    return Ghost.deserialize(bytes)
}

fun Route.crudEndpoints(appData: ArenaApplicationDeps, log: Logger = LoggerFactory.getLogger("crudRoutes")): Route =
    route("/crud/items") {
        get {
            val categoryParam = call.request.queryParameters["category"] ?: "electronics"
            val page = (call.request.queryParameters["page"]?.toIntOrNull() ?: 1).coerceAtLeast(1)
            val limit = (call.request.queryParameters["limit"]?.toIntOrNull() ?: 10).coerceIn(1, 50)
            val offset = (page - 1).toLong() * limit

            try {
                val items = withContext(Dispatchers.IO) {
                    transaction(appData.postgres, readOnly = true) {
                        ItemTable.selectAll()
                            .where { ItemTable.category eq categoryParam }
                            .orderBy(ItemTable.id, SortOrder.ASC)
                            .limit(limit).offset(offset)
                            .map(ItemTable::toDbItem)
                    }
                }
                call.respondGhost(CrudListResponse(items = items, total = items.size, page = page, limit = limit))
            } catch (e: Exception) {
                log.error("CRUD list failed", e)
                call.respond(HttpStatusCode.InternalServerError, "list failed")
            }
        }

        get("{id}") {
            val id = call.pathParameters["id"]?.toUIntOrNull() ?: run {
                call.respondText("bad id", status = HttpStatusCode.BadRequest)
                return@get
            }

            val cached = appData.crudCache.get(id)
            if (cached != null) {
                call.response.headers.append("X-Cache", "HIT")
                call.respondBytes(cached, ContentType.Application.Json)
                return@get
            }

            try {
                val row = withContext(Dispatchers.IO) {
                    transaction(appData.postgres, readOnly = true) {
                        ItemTable.selectAll()
                            .where { ItemTable.id eq id }
                            .limit(1)
                            .map(ItemTable::toDbItem)
                            .firstOrNull()
                    }
                }
                if (row == null) {
                    call.respondText("not found", status = HttpStatusCode.NotFound)
                    return@get
                }
                val body = Ghost.encodeToBytes(row)
                appData.crudCache.put(id, body)
                call.response.headers.append("X-Cache", "MISS")
                call.respondBytes(body, ContentType.Application.Json)
            } catch (e: Exception) {
                log.error("CRUD read failed", e)
                call.respond(HttpStatusCode.InternalServerError, "read failed")
            }
        }

        post {
            val req = try {
                call.receiveGhost<CrudCreateRequest>()
            } catch (_: Exception) {
                call.respondText("invalid body", status = HttpStatusCode.UnprocessableEntity)
                return@post
            }
            try {
                withContext(Dispatchers.IO) {
                    transaction(appData.postgres) {
                        ItemTable.upsert(
                            keys = arrayOf(ItemTable.id),
                            onUpdateExclude = listOf(ItemTable.ratingScore, ItemTable.ratingCount),
                        ) {
                            it[id] = req.id.toUInt()
                            it[name] = req.name
                            it[category] = req.category
                            it[price] = req.price
                            it[quantity] = req.quantity
                            it[active] = req.active
                            it[tags] = req.tags
                            it[ratingScore] = 0
                            it[ratingCount] = 0
                        }
                    }
                }
                appData.crudCache.invalidate(req.id.toUInt())
                val response = DbItem(
                    id = req.id, name = req.name, category = req.category,
                    price = req.price, quantity = req.quantity, active = req.active,
                    tags = req.tags, rating = RatingInfo(0, 0)
                )
                call.respondGhost(HttpStatusCode.Created, response)
            } catch (e: Exception) {
                log.error("CRUD create failed", e)
                call.respond(HttpStatusCode.InternalServerError, "create failed")
            }
        }

        put("{id}") {
            val id = call.pathParameters["id"]?.toUIntOrNull() ?: run {
                call.respondText("bad id", status = HttpStatusCode.BadRequest)
                return@put
            }
            val req = try {
                call.receiveGhost<CrudUpdateRequest>()
            } catch (_: Exception) {
                call.respondText("invalid body", status = HttpStatusCode.UnprocessableEntity)
                return@put
            }
            try {
                val updated = withContext(Dispatchers.IO) {
                    transaction(appData.postgres) {
                        val rows = ItemTable.update({ ItemTable.id eq id }) { stmt ->
                            req.name?.let { v -> stmt[ItemTable.name] = v }
                            req.price?.let { v -> stmt[ItemTable.price] = v }
                            req.quantity?.let { v -> stmt[ItemTable.quantity] = v }
                        }
                        if (rows == 0) {
                            null
                        } else {
                            ItemTable.selectAll()
                                .where { ItemTable.id eq id }
                                .limit(1)
                                .map(ItemTable::toDbItem)
                                .firstOrNull()
                        }
                    }
                }
                appData.crudCache.invalidate(id)
                if (updated == null) {
                    call.respondText("not found", status = HttpStatusCode.NotFound)
                } else {
                    call.respondGhost(HttpStatusCode.OK, updated)
                }
            } catch (e: Exception) {
                log.error("CRUD update failed", e)
                call.respond(HttpStatusCode.InternalServerError, "update failed")
            }
        }
    }
