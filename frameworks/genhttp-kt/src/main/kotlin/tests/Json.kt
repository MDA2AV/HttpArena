package genhttp.tests

import genhttp.DatasetItem
import genhttp.ListWithCount
import genhttp.ProcessedItem
import genhttp.infrastructure.JsonMapping

import org.genhttp.api.content.ProviderException
import org.genhttp.api.protocol.ResponseStatus
import org.genhttp.modules.webservices.ResourceMethod

import tools.jackson.module.kotlin.readValue

import java.io.File

class Json {

    @ResourceMethod(path = ":count")
    fun compute(count: Int, m: Int = 1): ListWithCount<ProcessedItem> {
        val datasetItems = DatasetItems ?: throw ProviderException(ResponseStatus.InternalServerError, "No dataset")

        val processed = datasetItems.subList(0, count.coerceIn(0, datasetItems.size)).map { d ->
            ProcessedItem(
                id = d.id, name = d.name, category = d.category,
                price = d.price, quantity = d.quantity, active = d.active,
                tags = d.tags, rating = d.rating,
                total = d.price.toLong() * d.quantity * m
            )
        }

        return ListWithCount(processed)
    }

    private companion object {

        val DatasetItems: List<DatasetItem>? = loadItems()

        fun loadItems(): List<DatasetItem>? {
            val datasetPath = File(System.getenv("DATASET_PATH") ?: "/data/dataset.json")

            if (datasetPath.exists()) {
                return JsonMapping.mapper.readValue(datasetPath)
            }

            return null
        }

    }

}
