package com.httparena.fishcake.services

import com.httparena.fishcake.Database
import com.httparena.fishcake.DbItem
import com.httparena.fishcake.ListWithCount
import org.codegreen.modules.webservices.ResourceMethod

/**
 * `GET /async-db?min=&max=&limit=` returns the items whose price falls within `[min, max]`
 * (a sequential scan over the `items` table). Degrades to an empty result when no database
 * is configured.
 */
class AsyncDatabase {

    @ResourceMethod
    suspend fun compute(min: Int = 10, max: Int = 50, limit: Int = 50): ListWithCount<DbItem> {
        if (!Database.available) return ListWithCount(emptyList())
        return ListWithCount(Database.rangeByPrice(min, max, limit.coerceIn(1, 50)))
    }
}
