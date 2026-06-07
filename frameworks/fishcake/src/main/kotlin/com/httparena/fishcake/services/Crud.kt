package com.httparena.fishcake.services

import com.httparena.fishcake.CrudCreateRequest
import com.httparena.fishcake.CrudListResponse
import com.httparena.fishcake.CrudUpdateRequest
import com.httparena.fishcake.Database
import com.httparena.fishcake.Dataset
import com.httparena.fishcake.DbItem
import com.httparena.fishcake.RatingInfo
import com.httparena.fishcake.crudCache
import org.codegreen.api.content.ProviderException
import org.codegreen.api.protocol.ContentType
import org.codegreen.api.protocol.Request
import org.codegreen.api.protocol.Response
import org.codegreen.api.protocol.ResponseStatus
import org.codegreen.modules.io.strings.StringContent
import org.codegreen.modules.reflection.Method
import org.codegreen.modules.reflection.Result
import org.codegreen.modules.webservices.ResourceMethod

/**
 * `/crud/items` REST service, mirroring the `genhttp-11` / `ktor` entries:
 *
 *  - `GET  /crud/items?category=&page=&limit=` — paged listing ordered by id
 *  - `GET  /crud/items/:id`                    — cached read reporting `X-Cache: HIT|MISS`
 *  - `POST /crud/items`                        — upsert, returns `201 Created`
 *  - `PUT  /crud/items/:id`                    — partial update, `404` when the id is unknown
 */
class Crud {

    @ResourceMethod
    suspend fun list(category: String = "electronics", page: Int = 1, limit: Int = 10): CrudListResponse {
        val resolvedPage = page.coerceAtLeast(1)
        val resolvedLimit = limit.coerceIn(1, 50)
        val offset = (resolvedPage - 1) * resolvedLimit

        if (!Database.available) return CrudListResponse(emptyList(), 0, resolvedPage, resolvedLimit)

        val items = Database.listByCategory(category, resolvedLimit, offset)
        return CrudListResponse(items, items.size, resolvedPage, resolvedLimit)
    }

    @ResourceMethod(path = ":id")
    suspend fun get(id: Int, request: Request): Response {
        crudCache.get(id)?.let { cached ->
            return request.respond()
                .content(StringContent(cached, ContentType.ApplicationJson))
                .header("X-Cache", "HIT")
                .build()
        }

        val item = (if (Database.available) Database.findById(id) else null)
            ?: throw ProviderException(ResponseStatus.NotFound, "Item with ID $id does not exist")

        val json = Dataset.json.encodeToString(item)
        crudCache.put(id, json)

        return request.respond()
            .content(StringContent(json, ContentType.ApplicationJson))
            .header("X-Cache", "MISS")
            .build()
    }

    @ResourceMethod(Method.Post)
    suspend fun create(item: CrudCreateRequest): Result<DbItem> {
        Database.upsert(item)
        crudCache.invalidate(item.id)

        val created = DbItem(
            id = item.id, name = item.name, category = item.category,
            price = item.price, quantity = item.quantity, active = item.active,
            tags = item.tags, rating = RatingInfo(0, 0),
        )
        return Result(created).status(ResponseStatus.Created)
    }

    @ResourceMethod(Method.Put, ":id")
    suspend fun update(id: Int, item: CrudUpdateRequest): DbItem {
        val updated = if (Database.available) Database.update(id, item) else false
        crudCache.invalidate(id)

        if (!updated) {
            throw ProviderException(ResponseStatus.NotFound, "Item with ID $id does not exist")
        }

        return Database.findById(id)
            ?: throw ProviderException(ResponseStatus.NotFound, "Item with ID $id does not exist")
    }
}
