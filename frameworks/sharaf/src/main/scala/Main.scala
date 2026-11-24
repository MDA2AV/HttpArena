import java.io.{ByteArrayInputStream, InputStream, OutputStream}
import java.net.InetSocketAddress
import java.nio.file.{Files, Paths}
import java.util.concurrent.Executors
import scala.util.control.NonFatal

import ba.sake.potateh.ServerConfig
import ba.sake.querson.QueryStringRW
import ba.sake.sharaf.{*, given}
import ba.sake.sharaf.potateh.{PotatehSharafServer, PotatehTls}
import ba.sake.tupson.*
import sttp.model.StatusCode

case class Rating(score: Int, count: Int) derives JsonRW
case class Item(
    id: Int,
    name: String,
    category: String,
    price: Long,
    quantity: Long,
    active: Boolean,
    tags: Seq[String],
    rating: Rating,
    total: Long = 0
) derives JsonRW
case class Payload(items: Seq[Item], count: Int) derives JsonRW

case class SumQuery(a: Long = 0L, b: Long = 0L) derives QueryStringRW

object Main {
  private val virtualThreads = Executors.newVirtualThreadPerTaskExecutor()
  private val database = Database.fromEnvironment()

  def main(args: Array[String]): Unit = {
    val datasetPath = sys.env.getOrElse("DATASET_PATH", "/data/dataset.json")
    val datasetJson = scala.util.Using.resource(scala.io.Source.fromFile(datasetPath))(_.mkString)
    val dataset = datasetJson.parseJson[Seq[Item]]
    val routes = Routes {
      case GET -> Path("pipeline") => Response.withBody("ok")
      case GET -> Path("baseline11") => Response.withBody(querySum.toString)
      case POST -> Path("baseline11") =>
        val body = Request.current.bodyString.trim.toLongOption.getOrElse(0L)
        Response.withBody((querySum + body).toString)
      case POST -> Path("echo") => binaryEcho()
      case POST -> Path("spec") => binaryEcho()
      case GET -> Path("spec") => specText
      case HEAD -> Path("spec") => specText
      case OPTIONS -> Path("spec") =>
        discardRequestBody()
        Response.withBody("").settingHeader("Allow", "GET, HEAD, POST, OPTIONS")
      case GET -> Path("spec", "headers") => specHeaders()
      case POST -> Path("spec", "headers") => specHeaders()
      case GET -> Path("json", count) =>
        case class JsonQuery(m: Long = 1L) derives QueryStringRW
        val multiplier = Request.current.queryParams[JsonQuery].m
        val itemCount = count.toIntOption.getOrElse(0).max(0)
        val items = dataset.take(itemCount).map { item =>
          item.copy(total = item.price * item.quantity * multiplier)
        }
        val payload = Payload(items, items.size)
        Response.withBody(payload)
      case GET -> Path("delay", milliseconds) =>
        val delay = milliseconds.toLongOption.getOrElse(0L).max(0L)
        Thread.sleep(delay)
        Response.withBody(delay.toString)
      case GET -> Path("async-db") =>
        case class DatabaseQuery(min: Int = 10, max: Int = 50, limit: Int = 50) derives QueryStringRW
        database match {
          case Some(db) =>
            val query = Request.current.queryParams[DatabaseQuery]
            Response.withBody(db.items(query.min, query.max, query.limit))
          case None => databaseUnavailable()
        }
      case GET -> Path("fortunes") =>
        database match {
          case Some(db) => Response.withBody(renderFortunes(db.fortunes()))
          case None     => databaseUnavailable()
        }
    }
    val config = ServerConfig.Default
      .withBindAddress(new InetSocketAddress("0.0.0.0", 8080))
      .withMaxConnections(32768)
      .withBacklog(8192)
      .withExecutor(virtualThreads)
    val routesHandler = SharafHandler.routes(routes)
    val gzipHandler = SharafHandler.gzip(routesHandler, GzipSettings.default.withLevel(1))
    val filesHandler = SharafHandler.files(Paths.get("/data"))
    val jsonCompression: SharafHandler = context =>
      if context.params.path.segments.headOption.contains("json") then gzipHandler.handle(context)
      else if context.params.path.segments.headOption.contains("static") then filesHandler.handle(context)
      else routesHandler.handle(context)
    val handler = SharafHandler.exceptions(jsonCompression, ExceptionMapper.default)
    val cert = Paths.get(sys.env.getOrElse("TLS_CERT", "/certs/server.crt"))
    val key = Paths.get(sys.env.getOrElse("TLS_KEY", "/certs/server.key"))
    val benchmarkServers = if Files.isRegularFile(cert) && Files.isRegularFile(key) then {
      val tlsConfig = PotatehTls.configure(
        config.withBindAddress(new InetSocketAddress("0.0.0.0", 8081)),
        new TlsConfig(ArenaTls.context(cert, key))
      )
      Seq(
        PotatehSharafServer(handler, "0.0.0.0", 8080).withConfig(config),
        PotatehSharafServer(handler, "0.0.0.0", 8081).withConfig(tlsConfig)
      )
    } else Seq(PotatehSharafServer(handler, "0.0.0.0", 8080).withConfig(config))
    val rotationCert = Paths.get("/certs-tls/server.crt")
    val rotationKey = Paths.get("/certs-tls/server.key")
    val rotationServers = Option.when(Files.isRegularFile(rotationCert) && Files.isRegularFile(rotationKey)) {
      val rotationConfig = config
        .withBindAddress(new InetSocketAddress("0.0.0.0", 9000))
        .withServerSocketFactory(() => ArenaTls.reloadingSocket(rotationCert, rotationKey))
      PotatehSharafServer(handler, "0.0.0.0", 9000).withConfig(rotationConfig)
    }
    val servers = benchmarkServers ++ rotationServers
    Runtime.getRuntime.addShutdownHook(
      new Thread(
        () => {
          servers.foreach(_.stop())
          database.foreach(_.close())
          virtualThreads.shutdownNow()
          ()
        },
        "sharaf-potateh-shutdown"
      )
    )
    try servers.foreach(_.start())
    catch {
      case NonFatal(error) =>
        servers.reverseIterator.foreach { server =>
          try server.stop()
          catch { case NonFatal(stopError) => error.addSuppressed(stopError) }
        }
        throw error
    }
  }

  private def binaryEcho()(using Request): Response[InputStream] = {
    // Consume the upload before committing the response so Potateh can reuse the connection.
    val bytes = Request.current.bodyInputStream.readAllBytes()
    val body: InputStream = new ByteArrayInputStream(bytes)
    Response.withBody(body).settingHeader("Content-Length", bytes.length.toString)
  }

  private val specText = Response.withBody("spec ok").settingHeader("Content-Length", "7")

  private def discardRequestBody()(using Request): Unit = {
    Request.current.bodyInputStream.transferTo(OutputStream.nullOutputStream())
    ()
  }

  private def specHeaders()(using Request): Response[String] = {
    discardRequestBody()
    val headers = Request.current.headers.iterator.flatMap { (name, values) =>
      values.iterator.map(value => s"${name.value}: $value")
    }
    Response.withBody(headers.mkString("\n"))
  }

  private def querySum(using Request): Long = {
    val query = Request.current.queryParams[SumQuery]
    query.a + query.b
  }

  private def databaseUnavailable(): Response[String] = {
    Response
      .withStatus(StatusCode.InternalServerError)
      .withBody("database unavailable")
  }

  private def renderFortunes(rows: Seq[Fortune]) = {
    val allRows = rows
      .appended(Fortune(0, "Additional fortune added at request time."))
      .sortBy(_.message)
    val renderedRows = allRows.map { fortune =>
      html"<tr><td>${fortune.id}</td><td>${fortune.message}</td></tr>"
    }
    html"""
      <!DOCTYPE html>
      <html>
      <head><title>Fortunes</title></head>
      <body><table>${renderedRows}</table></body>
      </html>
    """
  }
}
