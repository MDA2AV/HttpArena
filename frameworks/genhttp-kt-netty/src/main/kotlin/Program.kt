package genhttp

import genhttp.infrastructure.Certificates

import org.genhttp.api.infrastructure.CertificateProvider
import org.genhttp.engine.netty.Host
import org.genhttp.modules.compression.compression

import org.slf4j.helpers.NOPLoggerFactory

import java.io.File

import kotlin.system.exitProcess

suspend fun main() {
    val certPath = System.getenv("TLS_CERT") ?: "/certs/server.crt"
    val keyPath = System.getenv("TLS_KEY") ?: "/certs/server.key"
    val hasCert = File(certPath).exists() && File(keyPath).exists()

    val app = Project.create()

    val host = Host.create()
        .handler(app)
        .compression()
        .logging(NOPLoggerFactory(), false)

    host.bind(null, 8080)

    if (hasCert) {
        val certificateProvider = CertificateProvider.from(Certificates.fromPem(certPath, keyPath))

        host.bind(null, 8081, certificateProvider)
        host.bind(null, 8443, certificateProvider)
    }

    exitProcess(host.run())
}
