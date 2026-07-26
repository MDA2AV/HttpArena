package com.httparena.fishcake

import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.net.URI
import java.sql.Connection
import java.sql.ResultSet
import java.sql.Types

/**
 * PostgreSQL access for the `/async-db` and `/crud` workloads, mirroring the raw-SQL approach
 * of the C# `genhttp-11` entry (which uses Npgsql). Connections come from a HikariCP pool
 * configured from `DATABASE_URL`; blocking JDBC calls run on [Dispatchers.IO] so the engine's
 * event loop is never blocked. When `DATABASE_URL` is absent the pool is null and the
 * database-backed services degrade gracefully.
 */
object Database {

    private const val COLUMNS =
        "id, name, category, price, quantity, active, tags, rating_score, rating_count"

    private val dataSource: HikariDataSource? = createDataSource()

    val available: Boolean get() = dataSource != null

    private fun createDataSource(): HikariDataSource? {
        val url = System.getenv("DATABASE_URL")?.takeIf { it.isNotBlank() } ?: return null
        return runCatching {
            val uri = URI(url)
            val userInfo = (uri.userInfo ?: "").split(":")
            val maxConn = System.getenv("DATABASE_MAX_CONN")?.toIntOrNull()?.takeIf { it > 0 }
                ?: (Runtime.getRuntime().availableProcessors() * 2)

            HikariDataSource(HikariConfig().apply {
                jdbcUrl = "jdbc:postgresql://${uri.host}:${if (uri.port > 0) uri.port else 5432}${uri.path}"
                username = userInfo.getOrElse(0) { "" }
                password = userInfo.getOrElse(1) { "" }
                maximumPoolSize = maxConn
                minimumIdle = minOf(maxConn, 16)
                addDataSourceProperty("reWriteBatchedInserts", "true")
            })
        }.getOrNull()
    }

    private suspend fun <T> withConnection(block: (Connection) -> T): T {
        val source = dataSource ?: error("DATABASE_URL is not configured")
        return withContext(Dispatchers.IO) { source.connection.use(block) }
    }

    private fun ResultSet.toDbItem(): DbItem = DbItem(
        id = getInt("id"),
        name = getString("name"),
        category = getString("category"),
        price = getInt("price"),
        quantity = getInt("quantity"),
        active = getBoolean("active"),
        tags = Dataset.json.decodeFromString<List<String>>(getString("tags")),
        rating = RatingInfo(getInt("rating_score"), getInt("rating_count")),
    )

    suspend fun rangeByPrice(min: Int, max: Int, limit: Int): List<DbItem> = withConnection { conn ->
        conn.prepareStatement(
            "SELECT $COLUMNS FROM items WHERE price BETWEEN ? AND ? LIMIT ?",
        ).use { st ->
            st.setInt(1, min); st.setInt(2, max); st.setInt(3, limit)
            st.executeQuery().use { rs -> buildList { while (rs.next()) add(rs.toDbItem()) } }
        }
    }

    suspend fun listByCategory(category: String, limit: Int, offset: Int): List<DbItem> = withConnection { conn ->
        conn.prepareStatement(
            "SELECT $COLUMNS FROM items WHERE category = ? ORDER BY id LIMIT ? OFFSET ?",
        ).use { st ->
            st.setString(1, category); st.setInt(2, limit); st.setInt(3, offset)
            st.executeQuery().use { rs -> buildList { while (rs.next()) add(rs.toDbItem()) } }
        }
    }

    suspend fun findById(id: Int): DbItem? = withConnection { conn ->
        conn.prepareStatement("SELECT $COLUMNS FROM items WHERE id = ? LIMIT 1").use { st ->
            st.setInt(1, id)
            st.executeQuery().use { rs -> if (rs.next()) rs.toDbItem() else null }
        }
    }

    /** Inserts or updates a row, leaving the rating untouched on conflict (as the C# entry does). */
    suspend fun upsert(req: CrudCreateRequest): Unit = withConnection { conn ->
        conn.prepareStatement(
            "INSERT INTO items ($COLUMNS) VALUES (?, ?, ?, ?, ?, ?, ?::jsonb, 0, 0) " +
                "ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, category = EXCLUDED.category, " +
                "price = EXCLUDED.price, quantity = EXCLUDED.quantity, active = EXCLUDED.active, tags = EXCLUDED.tags",
        ).use { st ->
            st.setInt(1, req.id); st.setString(2, req.name); st.setString(3, req.category)
            st.setInt(4, req.price); st.setInt(5, req.quantity); st.setBoolean(6, req.active)
            st.setString(7, Dataset.json.encodeToString(req.tags))
            st.executeUpdate()
        }
    }

    /** Updates the provided fields only; returns false when the id does not exist. */
    suspend fun update(id: Int, req: CrudUpdateRequest): Boolean = withConnection { conn ->
        conn.prepareStatement(
            "UPDATE items SET name = COALESCE(?, name), price = COALESCE(?, price), " +
                "quantity = COALESCE(?, quantity) WHERE id = ?",
        ).use { st ->
            if (req.name != null) st.setString(1, req.name) else st.setNull(1, Types.VARCHAR)
            if (req.price != null) st.setInt(2, req.price) else st.setNull(2, Types.INTEGER)
            if (req.quantity != null) st.setInt(3, req.quantity) else st.setNull(3, Types.INTEGER)
            st.setInt(4, id)
            st.executeUpdate() > 0
        }
    }
}
