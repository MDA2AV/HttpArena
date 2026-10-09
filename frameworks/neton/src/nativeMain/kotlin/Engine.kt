import neton.core.http.adapter.HttpAdapter
import neton.core.http.adapter.HttpServerConfig
import neton.http.netonstream.NetonStreamHttpAdapter
import neton.http.netonstream.NetonStreamOptions

fun createEngine(config: HttpServerConfig): HttpAdapter = NetonStreamHttpAdapter(
    config,
    NetonStreamOptions(maxOpenConnections = config.maxConnections),
)
