package httparena

import kotlinx.serialization.Serializable

// The ktor entry's JSON types, serialized by kotlinx.serialization as there.

@Serializable
data class DatasetItem(
    val id: Int,
    val name: String,
    val category: String,
    val price: Int,
    val quantity: Int,
    val active: Boolean,
    val tags: List<String>,
    val rating: RatingInfo,
)

@Serializable
data class RatingInfo(
    val score: Int,
    val count: Int,
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
    val total: Long,
)

@Serializable
data class JsonResponse(
    val items: List<ProcessedItem>,
    val count: Int,
)
