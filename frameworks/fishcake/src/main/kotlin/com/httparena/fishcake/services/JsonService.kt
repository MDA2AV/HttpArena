package com.httparena.fishcake.services

import com.httparena.fishcake.Dataset
import com.httparena.fishcake.ListWithCount
import com.httparena.fishcake.ProcessedItem
import org.codegreen.api.content.ProviderException
import org.codegreen.api.protocol.ResponseStatus
import org.codegreen.modules.webservices.ResourceMethod

/**
 * `GET /json/:count?m=` processes the first `count` dataset items, scaling each item's total
 * (`price * quantity * m`, default multiplier 1). `count` is clamped to the dataset size.
 */
class JsonService {

    @ResourceMethod(path = ":count")
    fun compute(count: Int, m: Int = 1): ListWithCount<ProcessedItem> {
        if (Dataset.items.isEmpty()) {
            throw ProviderException(ResponseStatus.InternalServerError, "No dataset")
        }

        val take = count.coerceIn(0, Dataset.items.size)

        val processed = ArrayList<ProcessedItem>(take)
        for (i in 0 until take) {
            val d = Dataset.items[i]
            processed.add(
                ProcessedItem(
                    id = d.id, name = d.name, category = d.category,
                    price = d.price, quantity = d.quantity, active = d.active,
                    tags = d.tags, rating = d.rating,
                    total = d.price.toLong() * d.quantity * m,
                ),
            )
        }

        return ListWithCount(processed)
    }
}
