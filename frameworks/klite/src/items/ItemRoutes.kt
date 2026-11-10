package items

import klite.annotations.GET
import klite.annotations.QueryParam

data class ItemList(val items: List<Item>, val count: Int = items.size)

class ItemRoutes(private val items: ItemRepository) {
  @GET fun byPrice(@QueryParam min: Int = 10, @QueryParam max: Int = 50, @QueryParam limit: Int = 50) =
    ItemList(items.findByPrice(min..max, limit.coerceIn(1, 50)))
}
