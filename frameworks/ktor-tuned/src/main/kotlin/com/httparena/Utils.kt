package com.httparena

import com.zaxxer.hikari.HikariConfig
import com.zaxxer.hikari.HikariDataSource
import io.ktor.utils.io.core.discard
import kotlinx.io.Buffer
import kotlinx.io.RawSink
import kotlinx.serialization.json.Json
import org.jetbrains.exposed.v1.core.DatabaseConfig
import org.jetbrains.exposed.v1.jdbc.Database
import java.io.File
import java.net.URI
import java.security.KeyFactory
import java.security.KeyStore
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.security.spec.PKCS8EncodedKeySpec
import java.sql.Connection
import java.util.Base64
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
    private val map = ConcurrentHashMap<UInt, CacheEntry>()

    fun get(id: UInt): ByteArray? {
        val entry = map[id] ?: return null
        if (entry.expiresAt <= System.nanoTime()) {
            map.remove(id, entry)
            return null
        }
        return entry.body
    }

    fun put(id: UInt, body: ByteArray) {
        val expiresAt = System.nanoTime() + ttlMillis * 1_000_000L
        map[id] = CacheEntry(body, expiresAt)
    }

    fun invalidate(id: UInt) {
        map.remove(id)
    }
}

object DevNull : RawSink {
    override fun close() {}
    override fun flush() {}
    override fun write(source: Buffer, byteCount: Long) {
        source.discard(byteCount)
    }
}

val RUNTIME_FORTUNE = Fortune(
    id = 0,
    message = "Additional fortune added at request time."
)

const val CERT_PATH = "/certs/server.crt"
const val KEY_PATH = "/certs/server.key"
const val KEY_ALIAS = "server"
val KEYSTORE_PASSWORD = CharArray(0)

object ArenaApplicationDepsFactory {
    fun load(): ArenaApplicationDeps {
        val cpuCores = Runtime.getRuntime().availableProcessors()
        val certFile = File(CERT_PATH)
        val keyFile = File(KEY_PATH)
        val datasetFile = File(System.getenv("DATASET_PATH") ?: "/data/dataset.json")
        val json = Json { ignoreUnknownKeys = true }
        val crudCache = CrudCache(ttlMillis = 200)
        val dataset: List<DatasetItem> = datasetFile.takeIf { it.exists() }?.let {
            json.decodeFromString(it.readText())
        } ?: emptyList()

        val postgres: Database? = System.getenv("DATABASE_URL")?.let { dbUrl ->
            runCatching {
                val uri = URI(dbUrl.replace("postgres://", "postgresql://"))
                val host = uri.host
                val port = if (uri.port > 0) uri.port else 5432
                val database = uri.path.removePrefix("/")
                val userInfo = uri.userInfo.split(":")
                val user = userInfo[0]
                val password = if (userInfo.size > 1) userInfo[1] else ""
                val maxConn = System.getenv("DATABASE_MAX_CONN")?.toIntOrNull() ?: (cpuCores * 2)

                val hikariConfig = HikariConfig().apply {
                    jdbcUrl = "jdbc:postgresql://$host:$port/$database"
                    driverClassName = "org.postgresql.Driver"
                    username = user
                    this.password = password
                    maximumPoolSize = maxConn
                    minimumIdle = maxConn
                    isAutoCommit = false
                    transactionIsolation = "TRANSACTION_READ_COMMITTED"
                    validate()
                }
                val dataSource = HikariDataSource(hikariConfig)
                Database.connect(
                    datasource = dataSource,
                    databaseConfig = DatabaseConfig {
                        defaultIsolationLevel = Connection.TRANSACTION_READ_COMMITTED
                    }
                )
            }
        }?.getOrNull()

        val keystore: KeyStore? = certFile.takeIf { it.exists() }?.let { certFile ->
            val certs = CertificateFactory.getInstance("X.509")
                .generateCertificates(certFile.inputStream())
                .map { it as X509Certificate }
                .toTypedArray()

            val keyBytes = Base64.getMimeDecoder().decode(
                keyFile.readText()
                    .replace("-----BEGIN PRIVATE KEY-----", "")
                    .replace("-----END PRIVATE KEY-----", "")
                    .replace("\\s".toRegex(), "")
            )
            val privateKey = KeyFactory.getInstance("RSA")
                .generatePrivate(PKCS8EncodedKeySpec(keyBytes))

            KeyStore.getInstance("PKCS12").apply {
                load(null, null)
                setKeyEntry(KEY_ALIAS, privateKey, KEYSTORE_PASSWORD, certs)
            }
        }

        return ArenaApplicationDeps(
            json,
            crudCache,
            dataset,
            postgres,
            keystore
        )
    }
}

/**
 * Dependencies required for the HttpArena test array.
 * @property json JSON serializer.
 * @property crudCache Cache-aside store for the CRUD single-item read endpoint.
 * @property dataset Dataset from file.  Used in JSON endpoints.
 * @property keyStore Keystore for TLS.  Used in JSON TLS and JSON compressed endpoints.
 */
class ArenaApplicationDeps(
    val json: Json,
    val crudCache: CrudCache,
    val dataset: List<DatasetItem>,
    val postgres: Database?,
    val keyStore: KeyStore?,
)
