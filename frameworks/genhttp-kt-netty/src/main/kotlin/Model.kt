package genhttp

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

data class RatingInfo(
    val score: Int,
    val count: Int
)

class ListWithCount<T>(val items: List<T>) {

    val count: Int
        get() = items.size

}
