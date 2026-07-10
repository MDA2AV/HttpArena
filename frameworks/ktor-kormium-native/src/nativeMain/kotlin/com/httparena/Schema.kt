package com.httparena

import io.github.kormium.Catalog
import io.github.kormium.Column
import io.github.kormium.Entity
import io.github.kormium.Table

object Arena : Catalog

object Items : Table<Arena, Item>("items", ::Item) {
    val id by Column.Int().primaryKey()
    val name by Column.Text()
    val category by Column.Text()
    val price by Column.Int()
    val quantity by Column.Int()
    val active by Column.Boolean()
    val tags by Column.json<List<String>>()
    val ratingScore by Column.Int("rating_score")
    val ratingCount by Column.Int("rating_count")
}

class Item : Entity() {
    var id by Items.id
    var name by Items.name
    var category by Items.category
    var price by Items.price
    var quantity by Items.quantity
    var active by Items.active
    var tags by Items.tags
    var ratingScore by Items.ratingScore
    var ratingCount by Items.ratingCount
}

fun Item.toDbItem() = DbItem(
    id = id,
    name = name,
    category = category,
    price = price,
    quantity = quantity,
    active = active,
    tags = tags,
    rating = RatingInfo(ratingScore, ratingCount)
)

object Fortunes : Table<Arena, FortuneRow>("fortune", ::FortuneRow) {
    val id by Column.Int().primaryKey()
    val message by Column.Text()
}

class FortuneRow : Entity() {
    var id by Fortunes.id
    var message by Fortunes.message
}

fun FortuneRow.toFortune() = Fortune(id = id, message = message)
