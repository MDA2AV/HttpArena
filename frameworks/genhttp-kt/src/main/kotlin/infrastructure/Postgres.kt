package genhttp.infrastructure

import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource

import java.net.URI

object Postgres {

    val pool: HikariDataSource? = openPool()

    private fun openPool(): HikariDataSource? {
        val dbUrl = System.getenv("DATABASE_URL")

        if (dbUrl.isNullOrEmpty()) return null

        return try {
            val uri = URI(dbUrl)
            val userInfo = uri.userInfo.split(':')
            val port = if (uri.port > 0) uri.port else 5432
            val maxConn = System.getenv("DATABASE_MAX_CONN")?.toIntOrNull()?.takeIf { it > 0 } ?: 256

            val config = HikariConfig().apply {
                jdbcUrl = "jdbc:postgresql://${uri.host}:$port${uri.path}"
                username = userInfo[0]
                password = userInfo.getOrElse(1) { "" }
                maximumPoolSize = maxConn
                minimumIdle = minOf(64, maxConn)
                // connect lazily, so the server starts even if the database is not reachable yet
                initializationFailTimeout = -1
            }

            HikariDataSource(config)
        } catch (_: Exception) {
            null
        }
    }

}
