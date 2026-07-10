package com.httparena

import io.github.kormium.database.SuspendDatabase
import io.github.kormium.database.createDatabase
import io.ktor.util.collections.ConcurrentMap
import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.toKString
import kotlinx.io.buffered
import kotlinx.io.files.Path
import kotlinx.io.files.SystemFileSystem
import kotlinx.io.readString
import kotlinx.serialization.json.Json
import kotlin.time.Duration.Companion.milliseconds
import kotlin.time.TimeSource

@OptIn(ExperimentalForeignApi::class)
fun env(name: String): String? = platform.posix.getenv(name)?.toKString()

class CacheEntry(val body: ByteArray, val expiresAt: TimeSource.Monotonic.ValueTimeMark)

/**
 * Simple in-process cache-aside with 200 ms absolute TTL for CRUD single-item reads.
 * Stale entries are removed lazily on access.
 */
class CrudCache(private val ttlMillis: Long = 200) {
    private val map = ConcurrentMap<Int, CacheEntry>()

    fun get(id: Int): ByteArray? {
        val entry = map[id] ?: return null
        if (entry.expiresAt.hasPassedNow()) {
            map.remove(id)
            return null
        }
        return entry.body
    }

    fun put(id: Int, body: ByteArray) {
        val expiresAt = TimeSource.Monotonic.markNow() + ttlMillis.milliseconds
        map[id] = CacheEntry(body, expiresAt)
    }

    fun invalidate(id: Int) {
        map.remove(id)
    }
}

class ArenaApplicationDeps(
    val json: Json,
    val crudCache: CrudCache,
    val dataset: List<DatasetItem>,
    val postgres: SuspendDatabase<Arena>?,
)

/** Parses `postgres://user:pass@host:port/db` without java.net.URI. */
data class PgUrl(val host: String, val port: Int, val database: String, val user: String, val password: String)

fun parsePgUrl(url: String): PgUrl? {
    val withoutScheme = url.substringAfter("://", "").ifEmpty { return null }
    val userInfo = withoutScheme.substringBefore('@', "")
    val hostPart = withoutScheme.substringAfter('@')
    val hostPort = hostPart.substringBefore('/')
    val database = hostPart.substringAfter('/', "").substringBefore('?')
    return PgUrl(
        host = hostPort.substringBefore(':'),
        port = hostPort.substringAfter(':', "").toIntOrNull() ?: 5432,
        database = database.ifEmpty { "postgres" },
        user = userInfo.substringBefore(':'),
        password = userInfo.substringAfter(':', ""),
    )
}

object ArenaApplicationDepsFactory {
    fun load(): ArenaApplicationDeps {
        val json = Json { ignoreUnknownKeys = true }

        val datasetPath = Path(env("DATASET_PATH") ?: "/data/dataset.json")
        val dataset: List<DatasetItem> = runCatching {
            val text = SystemFileSystem.source(datasetPath).buffered().use { it.readString() }
            json.decodeFromString<List<DatasetItem>>(text)
        }.getOrDefault(emptyList())

        val postgres: SuspendDatabase<Arena>? = env("DATABASE_URL")?.let { dbUrl ->
            runCatching {
                val pg = parsePgUrl(dbUrl) ?: return@runCatching null
                val maxConn = env("DATABASE_MAX_CONN")?.toIntOrNull() ?: 64
                val db: SuspendDatabase<Arena> = createDatabase(
                    host = pg.host,
                    port = pg.port,
                    database = pg.database,
                    user = pg.user,
                    password = pg.password,
                    poolSize = maxConn,
                )
                db
            }.getOrNull()
        }

        return ArenaApplicationDeps(
            json,
            CrudCache(ttlMillis = 200),
            dataset,
            postgres,
        )
    }
}
