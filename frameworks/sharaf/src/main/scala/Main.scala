import java.net.InetSocketAddress
import java.util.concurrent.Executors

import ba.sake.potateh.ServerConfig
import ba.sake.querson.QueryStringRW
import ba.sake.sharaf.{*, given}
import ba.sake.sharaf.potateh.PotatehSharafServer
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
    val routesHandler = SharafHandler.routes(routes)
    val gzipHandler = SharafHandler.gzip(routesHandler, GzipSettings.default.withLevel(1))
    val jsonCompression: SharafHandler = context =>
      if context.params.path.segments.headOption.contains("json") then gzipHandler.handle(context)
      else routesHandler.handle(context)
    val handler = SharafHandler.exceptions(jsonCompression, ExceptionMapper.default)
    val server = PotatehSharafServer.start(config, handler, virtualThreads)
    Runtime.getRuntime.addShutdownHook(
      new Thread(
        () => {
          server.stop()
          database.foreach(_.close())
          virtualThreads.shutdownNow()
          ()
        },
        "sharaf-potateh-shutdown"
      )
    )
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
