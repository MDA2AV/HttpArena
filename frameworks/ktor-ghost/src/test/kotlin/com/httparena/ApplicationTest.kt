package com.httparena

import io.ktor.client.request.*
import io.ktor.client.statement.*
import io.ktor.http.*
import io.ktor.server.testing.*
import kotlinx.serialization.json.Json
import kotlin.test.Test
import kotlin.test.assertEquals

class ApplicationTest {

    private val testJson = Json { prettyPrint = true; ignoreUnknownKeys = true }

    private val sampleDataset = listOf(
        DatasetItem(
            id = 1, name = "Item-1", category = "electronics",
            price = 10, quantity = 2, active = true,
            tags = listOf("a", "b"), rating = RatingInfo(score = 5, count = 1)
        ),
        DatasetItem(
            id = 2, name = "Item-2", category = "books",
            price = 20, quantity = 3, active = false,
            tags = listOf("c"), rating = RatingInfo(score = 3, count = 2)
        ),
        DatasetItem(
            id = 3, name = "Item-3", category = "toys",
            price = 30, quantity = 1, active = true,
            tags = emptyList(), rating = RatingInfo(score = 4, count = 4)
        )
    )

    private fun buildTestDeps(dataset: List<DatasetItem> = emptyList()) = ArenaApplicationDeps(
        json = testJson,
        crudCache = CrudCache(),
        dataset = dataset,
        postgres = null,
        keyStore = null
    )

    private fun ApplicationTestBuilder.setup(deps: ArenaApplicationDeps = buildTestDeps()) {
        application { mainModule(deps) }
    }

    @Test
    fun baseline11Test() = testApplication {
        setup()
        val sum = client.get("/baseline11?a=2&b=2").let {
            assertEquals(200, it.status.value)
            it.bodyAsText().toLong()
        }
        assertEquals(4L, sum)
    }

    @Test
    fun pipelineTest() = testApplication {
        setup()
        val response = client.get("/pipeline")
        assertEquals(200, response.status.value)
        assertEquals("ok", response.bodyAsText())
    }

    @Test
    fun baseline11PostWithBodyTest() = testApplication {
        setup()
        val response = client.post("/baseline11?a=2&b=3") {
            setBody("10")
        }
        assertEquals(200, response.status.value)
        assertEquals(15L, response.bodyAsText().toLong())
    }

    @Test
    fun baseline11PostWithEmptyBodyTest() = testApplication {
        setup()
        val response = client.post("/baseline11?a=4&b=5")
        assertEquals(200, response.status.value)
        assertEquals(9L, response.bodyAsText().toLong())
    }

    @Test
    fun baseline2Test() = testApplication {
        setup()
        val response = client.get("/baseline2?x=7&y=8&z=10")
        assertEquals(200, response.status.value)
        assertEquals(25L, response.bodyAsText().toLong())
    }

    @Test
    fun jsonProcessingTest() = testApplication {
        setup(buildTestDeps(dataset = sampleDataset))
        val response = client.get("/json/2?m=3")
        assertEquals(200, response.status.value)
        val parsed = testJson.decodeFromString<JsonResponse>(response.bodyAsText())
        assertEquals(2, parsed.count)
        assertEquals(2, parsed.items.size)
        // total = price * quantity * m = 10 * 2 * 3 = 60 for the first item
        assertEquals(60L, parsed.items[0].total)
        assertEquals(1, parsed.items[0].id)
    }

    @Test
    fun jsonProcessingClampsCountTest() = testApplication {
        setup(buildTestDeps(dataset = sampleDataset))
        // Requesting more than the dataset size should be clamped to dataset size
        val response = client.get("/json/100")
        assertEquals(200, response.status.value)
        val parsed = testJson.decodeFromString<JsonResponse>(response.bodyAsText())
        assertEquals(sampleDataset.size, parsed.count)
        assertEquals(sampleDataset.size, parsed.items.size)
    }

    @Test
    fun jsonProcessingEmptyDatasetReturnsErrorTest() = testApplication {
        setup() // empty dataset
        val response = client.get("/json/1")
        assertEquals(HttpStatusCode.InternalServerError.value, response.status.value)
        assertEquals("Dataset not loaded", response.bodyAsText())
    }

    @Test
    fun uploadTest() = testApplication {
        setup()
        val payload = ByteArray(1024) { it.toByte() }
        val response = client.post("/upload") {
            setBody(payload)
        }
        assertEquals(200, response.status.value)
        assertEquals(payload.size.toLong(), response.bodyAsText().toLong())
    }

    @Test
    fun asyncDbWithoutDatabaseReturnsEmptyTest() = testApplication {
        setup()
        // With postgres = null, the handler catches the exception and returns an empty payload
        val response = client.get("/async-db?min=0&max=100&limit=10")
        assertEquals(200, response.status.value)
        assertEquals("{\"items\":[],\"count\":0}", response.bodyAsText())
    }

    @Test
    fun fortunesWithoutDatabaseReturnsErrorTest() = testApplication {
        setup()
        val response = client.get("/fortunes")
        assertEquals(HttpStatusCode.InternalServerError.value, response.status.value)
    }

    @Test
    fun crudListWithoutDatabaseReturnsErrorTest() = testApplication {
        setup()
        val response = client.get("/crud/items?category=electronics&page=1&limit=10")
        assertEquals(HttpStatusCode.InternalServerError.value, response.status.value)
        assertEquals("list failed", response.bodyAsText())
    }

    @Test
    fun crudGetByIdBadIdTest() = testApplication {
        setup()
        val response = client.get("/crud/items/not-a-number")
        assertEquals(HttpStatusCode.BadRequest.value, response.status.value)
        assertEquals("bad id", response.bodyAsText())
    }

    @Test
    fun crudGetByIdCacheHitTest() = testApplication {
        val deps = buildTestDeps()
        val cachedItem = DbItem(
            id = 42L, name = "cached", category = "electronics",
            price = 5, quantity = 1, active = true,
            tags = listOf("cached"), rating = RatingInfo(score = 0, count = 0)
        )
        val cachedBody = testJson.encodeToString(cachedItem).toByteArray()
        deps.crudCache.put(42u, cachedBody)

        setup(deps)
        val response = client.get("/crud/items/42")
        assertEquals(200, response.status.value)
        assertEquals("HIT", response.headers["X-Cache"])
        val parsed = testJson.decodeFromString<DbItem>(response.bodyAsText())
        assertEquals(42L, parsed.id)
        assertEquals("cached", parsed.name)
    }

    @Test
    fun crudGetByIdWithoutDatabaseReturnsErrorTest() = testApplication {
        setup()
        val response = client.get("/crud/items/123")
        assertEquals(HttpStatusCode.InternalServerError.value, response.status.value)
        assertEquals("read failed", response.bodyAsText())
    }

    @Test
    fun crudCreateInvalidBodyTest() = testApplication {
        setup()
        val response = client.post("/crud/items") {
            contentType(ContentType.Application.Json)
            setBody("{not-json}")
        }
        assertEquals(HttpStatusCode.UnprocessableEntity.value, response.status.value)
        assertEquals("invalid body", response.bodyAsText())
    }

    @Test
    fun crudCreateWithoutDatabaseReturnsErrorTest() = testApplication {
        setup()
        val body = testJson.encodeToString(
            CrudCreateRequest(
                id = 1L, name = "x", category = "electronics",
                price = 1, quantity = 1, active = true, tags = listOf("t")
            )
        )
        val response = client.post("/crud/items") {
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        assertEquals(HttpStatusCode.InternalServerError.value, response.status.value)
        assertEquals("create failed", response.bodyAsText())
    }

    @Test
    fun crudUpdateBadIdTest() = testApplication {
        setup()
        val response = client.put("/crud/items/not-a-number") {
            contentType(ContentType.Application.Json)
            setBody("{}")
        }
        assertEquals(HttpStatusCode.BadRequest.value, response.status.value)
        assertEquals("bad id", response.bodyAsText())
    }

    @Test
    fun crudUpdateInvalidBodyTest() = testApplication {
        setup()
        val response = client.put("/crud/items/1") {
            contentType(ContentType.Application.Json)
            setBody("{not-json}")
        }
        assertEquals(HttpStatusCode.UnprocessableEntity.value, response.status.value)
        assertEquals("invalid body", response.bodyAsText())
    }

    @Test
    fun crudUpdateWithoutDatabaseReturnsErrorTest() = testApplication {
        setup()
        val body = testJson.encodeToString(CrudUpdateRequest(name = "new-name", price = 99, quantity = 5))
        val response = client.put("/crud/items/1") {
            contentType(ContentType.Application.Json)
            setBody(body)
        }
        assertEquals(HttpStatusCode.InternalServerError.value, response.status.value)
        assertEquals("update failed", response.bodyAsText())
    }

    @Test
    fun unknownRouteReturns404Test() = testApplication {
        setup()
        val response = client.get("/does-not-exist")
        assertEquals(HttpStatusCode.NotFound.value, response.status.value)
    }

}
