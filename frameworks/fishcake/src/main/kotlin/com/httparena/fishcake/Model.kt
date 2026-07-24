package com.httparena.fishcake

import kotlinx.serialization.Serializable

/**
 * Data model for the HttpArena workloads, matching the shapes used by the C# `genhttp-11`
 * entry and the `ktor` reference entry (camelCase JSON; `rating` is a nested object).
 */

@Serializable
data class RatingInfo(val score: Int = 0, val count: Int = 0)

/** A raw dataset record, loaded from `dataset.json` and used by the `/json` workload. */
@Serializable
data class DatasetItem(
    val id: Int,
    val name: String = "",
    val category: String = "",
    val price: Int = 0,
    val quantity: Int = 0,
    val active: Boolean = false,
    val tags: List<String> = emptyList(),
    val rating: RatingInfo = RatingInfo(),
)

/** A dataset record enriched with a computed [total] (`/json` output). */
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
    val total: Long,
)

/** A row from the `items` table (`/async-db` and `/crud`). */
@Serializable
data class DbItem(
    val id: Int,
    val name: String,
    val category: String,
    val price: Int,
    val quantity: Int,
    val active: Boolean,
    val tags: List<String>,
    val rating: RatingInfo,
)

/** Serialized as `{ "items": [...], "count": N }` — matches `JsonResponse`/`DbResponse`. */
@Serializable
class ListWithCount<T>(val items: List<T>) {
    val count: Int = items.size
}

@Serializable
data class CrudListResponse(
    val items: List<DbItem>,
    val total: Int,
    val page: Int,
    val limit: Int,
)

@Serializable
data class CrudCreateRequest(
    val id: Int,
    val name: String,
    val category: String,
    val price: Int,
    val quantity: Int,
    val active: Boolean = false,
    val tags: List<String> = emptyList(),
)

@Serializable
data class CrudUpdateRequest(
    val name: String? = null,
    val price: Int? = null,
    val quantity: Int? = null,
)
