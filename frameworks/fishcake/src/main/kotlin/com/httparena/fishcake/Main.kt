package com.httparena.fishcake

import kotlinx.coroutines.runBlocking
import org.codegreen.engine.internal.Host
import org.codegreen.modules.io.Compression
import java.io.File
import java.net.InetAddress
import kotlin.system.exitProcess

/**
 * HttpArena entry "fishcake": the CodeGreen Kotlin port of GenHTTP, configured like the C#
 * `genhttp-11` entry. Serves on `0.0.0.0:8080` (HTTP/1.1).
 */
fun main() {
    // Touch the singletons up front so the dataset is parsed and the DB pool is opened
    // before the first request arrives.
    val datasetSize = Dataset.items.size

    // Plain HTTP/1.1 on :8080; HTTPS on :8081 when the harness mounts a certificate (json-tls).
    val host = Host.create()
        .handler(Project.create())
        .add(Compression.default())
        .bind(null, 8080)

    val certificate = File(System.getenv("TLS_CERT") ?: "/certs/server.crt")
    val key = File(System.getenv("TLS_KEY") ?: "/certs/server.key")
    val tls = certificate.exists() && key.exists()
    if (tls) host.bind(InetAddress.getByName("0.0.0.0"), 8081, certificate, key)

    println("fishcake (CodeGreen) starting on :8080${if (tls) " + TLS on :8081" else ""} — dataset items: $datasetSize, database: ${if (Database.available) "connected" else "disabled"}")

    val exitCode = runBlocking { host.run() }

    exitProcess(exitCode)
}
