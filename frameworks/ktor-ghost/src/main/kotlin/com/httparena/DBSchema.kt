package com.httparena

import kotlinx.serialization.json.Json
import org.jetbrains.exposed.v1.core.ResultRow
import org.jetbrains.exposed.v1.core.Table
import org.jetbrains.exposed.v1.core.dao.id.UIntIdTable
import org.jetbrains.exposed.v1.json.jsonb

object ItemTable: UIntIdTable("items") {
    val name = text("name")
    val category = text("category")
    val price = integer("price")
    val quantity = integer("quantity")
    val active = bool("active")
    val tags = jsonb<List<String>>("tags", Json)
    val ratingScore = integer("rating_score")
    val ratingCount = integer("rating_count")

    fun toDbItem(row: ResultRow) = DbItem(
        id = row[id].value.toLong(),
        name = row[name],
        category = row[category],
        price = row[price],
        quantity = row[quantity],
        active = row[active],
        tags = row[tags],
        rating = RatingInfo(
            row[ratingScore],
            row[ratingCount]
        )
    )
}

object FortuneTable : Table("fortune") {
    val id = integer("id")
    val message = text("message")

    fun toFortune(row: ResultRow) = Fortune(
        id = row[id],
        message = row[message]
    )
}
