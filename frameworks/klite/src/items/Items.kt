package items

import klite.jdbc.JsonColumn
import klite.jdbc.between
import klite.jdbc.create
import klite.jdbc.select
import javax.sql.DataSource

data class Rating(val score: Int, val count: Int)

data class Item(
  val id: Int,
  val name: String,
  val category: String,
  val price: Int,
  val quantity: Int,
  val active: Boolean,
  @JsonColumn val tags: List<String>,
  val rating: Rating,
)

class ItemRepository(private val db: DataSource) {
  fun findByPrice(range: ClosedRange<Int>, limit: Int): List<Item> =
    db.select("items", Item::price between range, suffix = "limit $limit") {
      create(Item::rating to Rating(getInt("rating_score"), getInt("rating_count")))
    }
}
