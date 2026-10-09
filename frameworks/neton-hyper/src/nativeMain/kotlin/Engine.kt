import neton.core.http.adapter.HttpAdapter
import neton.core.http.adapter.HttpServerConfig
import neton.http.hyper4k.Hyper4kHttpAdapter

fun createEngine(config: HttpServerConfig): HttpAdapter = Hyper4kHttpAdapter(config)
