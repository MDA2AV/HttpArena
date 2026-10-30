package httparena

import io.ktor.server.application.install
import io.ktor.server.plugins.compression.Compression
import io.ktor.server.plugins.compression.gzip
import io.ktor.server.routing.Route

fun main() = serve { "JVM ${Runtime.version()}" }

actual fun Route.installCompression() {
    install(Compression) {
        gzip()
    }
}
