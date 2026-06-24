package com.httparena

import com.ghost.serialization.annotations.GhostSerialization
import kotlinx.serialization.Serializable

@Serializable
@GhostSerialization
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
@GhostSerialization
data class RatingInfo(
    val score: Int,
    val count: Int
)

@Serializable
@GhostSerialization
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
@GhostSerialization
data class JsonResponse(
    val items: List<ProcessedItem>,
    val count: Int
)

@Serializable
@GhostSerialization
data class DbItem(
    val id: Long,
    val name: String,
    val category: String,
    val price: Int,
    val quantity: Int,
    val active: Boolean,
    val tags: List<String>,
    val rating: RatingInfo
)

@Serializable
@GhostSerialization
data class DbResponse(
    val items: List<DbItem>,
    val count: Int
) {
    companion object {
        fun List<DbItem>.toResponse() = DbResponse(this, size)
    }
}

@Serializable
@GhostSerialization
data class CrudListResponse(
    val items: List<DbItem>,
    val total: Int,
    val page: Int,
    val limit: Int
)

@Serializable
@GhostSerialization
data class CrudCreateRequest(
    val id: Long,
    val name: String,
    val category: String,
    val price: Int,
    val quantity: Int,
    val active: Boolean = false,
    val tags: List<String> = emptyList()
)

@Serializable
@GhostSerialization
data class CrudUpdateRequest(
    val name: String? = null,
    val price: Int? = null,
    val quantity: Int? = null
)

data class Fortune(
    val id: Int,
    val message: String
)
