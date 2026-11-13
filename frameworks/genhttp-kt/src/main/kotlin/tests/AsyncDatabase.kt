package genhttp.tests

import genhttp.DatasetItem
import genhttp.ListWithCount
import genhttp.RatingInfo
import genhttp.infrastructure.JsonMapping
import genhttp.infrastructure.Postgres

import org.genhttp.modules.webservices.ResourceMethod

import tools.jackson.module.kotlin.readValue

/**
 * Queries the database via JDBC.
 *
 * The engine runs every request on a virtual thread, so a blocking call only parks that virtual
 * thread and releases its carrier while waiting for the database.
 */
class AsyncDatabase {

    @ResourceMethod
    fun compute(min: Int = 10, max: Int = 50, limit: Int = 50): ListWithCount<DatasetItem> {
        val pool = Postgres.pool ?: return ListWithCount(emptyList())

        val items = ArrayList<DatasetItem>(limit)

        pool.connection.use { connection ->
            connection.prepareStatement(Query).use { statement ->
                statement.setInt(1, min)
                statement.setInt(2, max)
                statement.setInt(3, limit)

                statement.executeQuery().use { reader ->
                    while (reader.next()) {
                        items.add(
                            DatasetItem(
                                id = reader.getInt(1),
                                name = reader.getString(2),
                                category = reader.getString(3),
                                price = reader.getInt(4),
                                quantity = reader.getInt(5),
                                active = reader.getBoolean(6),
                                tags = JsonMapping.mapper.readValue(reader.getString(7)),
                                rating = RatingInfo(score = reader.getInt(8), count = reader.getInt(9))
                            )
                        )
                    }
                }
            }
        }

        return ListWithCount(items)
    }

    private companion object {

        const val Query = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT ?"

    }

}
