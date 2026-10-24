package arena

import com.ghost.serialization.annotations.GhostSerialization

@GhostSerialization
data class Rating(val score: Int, val count: Int)

/** An entry of /data/dataset.json, as it is read at startup. */
@GhostSerialization
data class DatasetItem(
    val id: Int,
    val name: String,
    val category: String,
    val price: Int,
    val quantity: Int,
    val active: Boolean,
    val tags: List<String>,
    val rating: Rating,
)

/** An item as /json answers it: the dataset's fields and the total its request's multiplier gives. */
@GhostSerialization
data class Item(
    val id: Int,
    val name: String,
    val category: String,
    val price: Int,
    val quantity: Int,
    val active: Boolean,
    val tags: List<String>,
    val rating: Rating,
    var total: Long,
)

@GhostSerialization
data class JsonResponse(val items: List<Item>, var count: Int)

/** The first [size] of [items], so one response object serves every count without a list per request. */
class Window(private val items: Array<Item>) : AbstractList<Item>() {
    override var size: Int = 0

    override fun get(index: Int): Item {
        if (index >= size) throw IndexOutOfBoundsException("$index of $size")
        return items[index]
    }
}
