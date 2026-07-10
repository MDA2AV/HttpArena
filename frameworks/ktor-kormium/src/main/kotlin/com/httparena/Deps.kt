package com.httparena

import io.github.kormium.database.SuspendDatabase
import io.github.kormium.database.createDatabase
import kotlinx.serialization.json.Json
import java.io.File
import java.net.URI
import java.util.concurrent.ConcurrentHashMap

/**
 * Cache entry holding pre-serialized JSON bytes and an absolute expiration time
 * (in nanos from [System.nanoTime]).  Used by the CRUD single-item read endpoint.
 */
class CacheEntry(val body: ByteArray, val expiresAt: Long)

/**
 * Simple in-process cache-aside with 200 ms absolute TTL for CRUD single-item reads.
 * Stale entries are removed lazily on access.
 */
class CrudCache(private val ttlMillis: Long = 200) {
    private val map = ConcurrentHashMap<Int, CacheEntry>()

    fun get(id: Int): ByteArray? {
        val entry = map[id] ?: return null
        if (entry.expiresAt <= System.nanoTime()) {
            map.remove(id, entry)
            return null
        }
        return entry.body
    }

    fun put(id: Int, body: ByteArray) {
        val expiresAt = System.nanoTime() + ttlMillis * 1_000_000L
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

object ArenaApplicationDepsFactory {
    fun load(): ArenaApplicationDeps {
        val cpuCores = Runtime.getRuntime().availableProcessors()
        val datasetFile = File(System.getenv("DATASET_PATH") ?: "/data/dataset.json")
        val json = Json { ignoreUnknownKeys = true }
        val dataset: List<DatasetItem> = datasetFile.takeIf { it.exists() }?.let {
            json.decodeFromString(it.readText())
        } ?: emptyList()

        val postgres: SuspendDatabase<Arena>? = System.getenv("DATABASE_URL")?.let { dbUrl ->
            runCatching {
                val uri = URI(dbUrl.replace("postgres://", "postgresql://"))
                val userInfo = uri.userInfo.split(":")
                val maxConn = System.getenv("DATABASE_MAX_CONN")?.toIntOrNull() ?: (cpuCores * 2)
                val db: SuspendDatabase<Arena> = createDatabase(
                    host = uri.host,
                    port = if (uri.port > 0) uri.port else 5432,
                    database = uri.path.removePrefix("/"),
                    user = userInfo[0],
                    password = if (userInfo.size > 1) userInfo[1] else "",
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
