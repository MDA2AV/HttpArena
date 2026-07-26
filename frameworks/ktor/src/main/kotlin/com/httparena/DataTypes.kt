package com.httparena

import kotlinx.serialization.Serializable

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
    val id: UInt,
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
) {
    companion object {
        fun List<DbItem>.toResponse() = DbResponse(this, size)
    }
}

@Serializable
data class CrudListResponse(
    val items: List<DbItem>,
    val total: Int,
    val page: Int,
    val limit: Int
)

@Serializable
data class CrudCreateRequest(
    val id: UInt,
    val name: String,
    val category: String,
    val price: Int,
    val quantity: Int,
    val active: Boolean = false,
    val tags: List<String> = emptyList()
)

@Serializable
data class CrudUpdateRequest(
    val name: String? = null,
    val price: Int? = null,
    val quantity: Int? = null
)

data class Fortune(
    val id: Int,
    val message: String
)
