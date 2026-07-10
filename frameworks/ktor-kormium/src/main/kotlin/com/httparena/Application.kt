package com.httparena

import com.httparena.DbResponse.Companion.toResponse
import io.github.kormium.between
import io.github.kormium.eq
import io.github.kormium.suspendTransaction
import io.ktor.http.*
import io.ktor.http.content.*
import io.ktor.serialization.kotlinx.json.*
import io.ktor.server.application.*
import io.ktor.server.engine.*
import io.ktor.server.html.*
import io.ktor.server.netty.*
import io.ktor.server.plugins.contentnegotiation.*
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import kotlinx.html.*
import kotlinx.serialization.encodeToString
import org.slf4j.Logger
import org.slf4j.LoggerFactory

fun main() {
    println("Ktor+Kormium HttpArena server starting on :8080 (HTTP/1.1)")
    val deps = ArenaApplicationDepsFactory.load()
    val environment = applicationEnvironment {}

    embeddedServer(Netty, environment, {
        connector {
            port = 8080
            host = "0.0.0.0"
        }
    }) {
        mainModule(deps)
    }.start(wait = true)
}

internal fun Application.mainModule(appData: ArenaApplicationDeps) {
    configureRouting(appData)
}

private fun Application.configureRouting(appData: ArenaApplicationDeps) {
    val pipelineResponse = ByteArrayContent("ok".toByteArray(), ContentType.Text.Plain)

    fun ApplicationCall.sumQueryParams(): Long {
        var start = 0
        var sum = 0L
        for (i in request.uri.indices) {
            when (request.uri[i]) {
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

        post("/baseline11") {
            val sum = call.sumQueryParams()
            val body = call.receiveText().trim().toLongOrNull() ?: run {
                call.respondText(sum.toString(), ContentType.Text.Plain)
                return@post
            }
            call.respondNumber(sum + body)
        }

        /**
         * JSON processing
         * https://www.http-arena.com/docs/test-profiles/h1/isolated/json-processing/
         */
        route("/json/{count}") {
            install(ContentNegotiation) {
                json(appData.json)
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
                call.respond(JsonResponse(items = processed, count = count))
            }
        }

        /**
         * Async DB
         * https://www.http-arena.com/docs/test-profiles/h1/isolated/async-database/
         */
        route("/async-db") {
            install(ContentNegotiation) {
                json(appData.json)
            }
            get {
                val db = appData.postgres ?: run {
                    call.respondText("{\"items\":[],\"count\":0}", ContentType.Application.Json)
                    return@get
                }
                val min = call.request.queryParameters["min"]?.toIntOrNull() ?: 10
                val max = call.request.queryParameters["max"]?.toIntOrNull() ?: 50
                val limitParam = (call.request.queryParameters["limit"]?.toIntOrNull() ?: 50).coerceIn(1, 50)
                try {
                    val items = db.suspendTransaction(readOnly = true) {
                        Items.find {
                            where { Items.price between min..max }
                            limit = limitParam
                        }
                    }.map { it.toDbItem() }
                    call.respond(items.toResponse())
                } catch (e: Exception) {
                    log.error("Failed to load items from DB", e)
                    call.respondText("{\"items\":[],\"count\":0}", ContentType.Application.Json)
                }
            }
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
            val db = appData.postgres ?: run {
                call.respond(HttpStatusCode.InternalServerError, "fortunes failed")
                return@get
            }
            val fortunes = mutableListOf<Fortune>()
            try {
                db.suspendTransaction(readOnly = true) {
                    Fortunes.all()
                }.mapTo(fortunes) { it.toFortune() }
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

fun Route.crudEndpoints(appData: ArenaApplicationDeps, log: Logger = LoggerFactory.getLogger("crudRoutes")): Route =
    route("/crud/items") {
        install(ContentNegotiation) {
            json(appData.json)
        }
        get {
            val db = appData.postgres ?: run {
                call.respond(HttpStatusCode.InternalServerError, "list failed")
                return@get
            }
            val categoryParam = call.request.queryParameters["category"] ?: "electronics"
            val page = (call.request.queryParameters["page"]?.toIntOrNull() ?: 1).coerceAtLeast(1)
            val limitParam = (call.request.queryParameters["limit"]?.toIntOrNull() ?: 10).coerceIn(1, 50)
            val offsetParam = ((page - 1L) * limitParam).coerceAtMost(Int.MAX_VALUE.toLong()).toInt()

            try {
                val items = db.suspendTransaction(readOnly = true) {
                    Items.find {
                        where { Items.category eq categoryParam }
                        orderBy ASC Items.id
                        limit = limitParam
                        offset = offsetParam
                    }
                }.map { it.toDbItem() }
                call.respond(CrudListResponse(items = items, total = items.size, page = page, limit = limitParam))
            } catch (e: Exception) {
                log.error("CRUD list failed", e)
                call.respond(HttpStatusCode.InternalServerError, "list failed")
            }
        }

        get("{id}") {
            val db = appData.postgres ?: run {
                call.respond(HttpStatusCode.InternalServerError, "read failed")
                return@get
            }
            val id = call.pathParameters["id"]?.toIntOrNull() ?: run {
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
                val row = db.suspendTransaction(readOnly = true) {
                    Items.findOne { where { Items.id eq id } }
                }?.toDbItem()
                if (row == null) {
                    call.respondText("not found", status = HttpStatusCode.NotFound)
                    return@get
                }
                val body = appData.json.encodeToString(row).toByteArray()
                appData.crudCache.put(id, body)
                call.response.headers.append("X-Cache", "MISS")
                call.respondBytes(body, ContentType.Application.Json)
            } catch (e: Exception) {
                log.error("CRUD read failed", e)
                call.respond(HttpStatusCode.InternalServerError, "read failed")
            }
        }

        post {
            val db = appData.postgres ?: run {
                call.respond(HttpStatusCode.InternalServerError, "create failed")
                return@post
            }
            val req = try {
                call.receive<CrudCreateRequest>()
            } catch (_: Exception) {
                call.respondText("invalid body", status = HttpStatusCode.UnprocessableEntity)
                return@post
            }
            try {
                db.suspendTransaction {
                    Items.upsert(
                        entity = Item().apply {
                            id = req.id
                            name = req.name
                            category = req.category
                            price = req.price
                            quantity = req.quantity
                            active = req.active
                            tags = req.tags
                            ratingScore = 0
                            ratingCount = 0
                        },
                        onConflict = Items.id,
                        // Rating fields stay untouched on conflict — they are not
                        // assigned on the update patch.
                        update = Item().apply {
                            name = req.name
                            category = req.category
                            price = req.price
                            quantity = req.quantity
                            active = req.active
                            tags = req.tags
                        },
                    )
                }
                appData.crudCache.invalidate(req.id)
                val response = DbItem(
                    id = req.id, name = req.name, category = req.category,
                    price = req.price, quantity = req.quantity, active = req.active,
                    tags = req.tags, rating = RatingInfo(0, 0)
                )
                call.respond(HttpStatusCode.Created, response)
            } catch (e: Exception) {
                log.error("CRUD create failed", e)
                call.respond(HttpStatusCode.InternalServerError, "create failed")
            }
        }

        put("{id}") {
            val db = appData.postgres ?: run {
                call.respond(HttpStatusCode.InternalServerError, "update failed")
                return@put
            }
            val id = call.pathParameters["id"]?.toIntOrNull() ?: run {
                call.respondText("bad id", status = HttpStatusCode.BadRequest)
                return@put
            }
            val req = try {
                call.receive<CrudUpdateRequest>()
            } catch (_: Exception) {
                call.respondText("invalid body", status = HttpStatusCode.UnprocessableEntity)
                return@put
            }
            try {
                val updated = db.suspendTransaction {
                    val patch = Item().apply {
                        req.name?.let { name = it }
                        req.price?.let { price = it }
                        req.quantity?.let { quantity = it }
                    }
                    val rows = Items.update(patch) { where { Items.id eq id } }
                    if (rows == 0L) {
                        null
                    } else {
                        Items.findOne { where { Items.id eq id } }?.toDbItem()
                    }
                }
                appData.crudCache.invalidate(id)
                if (updated == null) {
                    call.respondText("not found", status = HttpStatusCode.NotFound)
                } else {
                    call.respond(HttpStatusCode.OK, updated)
                }
            } catch (e: Exception) {
                log.error("CRUD update failed", e)
                call.respond(HttpStatusCode.InternalServerError, "update failed")
            }
        }
    }
