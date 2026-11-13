package genhttp.infrastructure

import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource

import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers

import java.net.URI

object Postgres {

    private val maxConnections = System.getenv("DATABASE_MAX_CONN")?.toIntOrNull()?.takeIf { it > 0 } ?: 256

    val pool: HikariDataSource? = openPool()

    /**
     * Runs the blocking JDBC calls, with as many threads as the pool has connections (the IO dispatcher
     * alone would stop at 64).
     */
    val dispatcher: CoroutineDispatcher = Dispatchers.IO.limitedParallelism(maxConnections)

    private fun openPool(): HikariDataSource? {
        val dbUrl = System.getenv("DATABASE_URL")

        if (dbUrl.isNullOrEmpty()) return null

        return try {
            val uri = URI(dbUrl)
            val userInfo = uri.userInfo.split(':')
            val port = if (uri.port > 0) uri.port else 5432

            val config = HikariConfig().apply {
                jdbcUrl = "jdbc:postgresql://${uri.host}:$port${uri.path}"
                username = userInfo[0]
                password = userInfo.getOrElse(1) { "" }
                maximumPoolSize = maxConnections
                minimumIdle = minOf(64, maxConnections)
                // connect lazily, so the server starts even if the database is not reachable yet
                initializationFailTimeout = -1
            }

            HikariDataSource(config)
        } catch (_: Exception) {
            null
        }
    }

}
