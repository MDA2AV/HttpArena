//> using scala 3.9.0
//> using platform native
//> using nativeVersion 0.5.12
//> using dep ba.sake::sharaf-potateh::0.21.0
//> using options -Yretain-trees

import java.net.InetSocketAddress
import ba.sake.potateh.ServerConfig
import ba.sake.querson.QueryStringRW
import ba.sake.sharaf.*
import ba.sake.sharaf.potateh.PotatehSharafServer
import ba.sake.tupson.*

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

object Main {
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
        case class Query(m: Long = 1L) derives QueryStringRW
        val multiplier = Request.current.queryParams[Query].m
        val items = dataset.take(count.toIntOption.getOrElse(0).max(0)).map { item =>
          item.copy(total = item.price * item.quantity * multiplier)
        }
        Response.withBody(Payload(items, items.size))
      case GET -> Path("delay", ms) =>
        val delay = ms.toLongOption.getOrElse(0L).max(0L)
        Thread.sleep(delay)
        Response.withBody(delay.toString)
    }
    val config = ServerConfig.Default
      .withBindAddress(new InetSocketAddress("0.0.0.0", 8080))
      .withMaxConnections(8192)
    val server = PotatehSharafServer.start(config, routes)
    Runtime.getRuntime.addShutdownHook(new Thread(() => server.stop()))
  }

  private def querySum(using Request): Long = {
    case class Query(a: Long = 0L, b: Long = 0L) derives QueryStringRW
    val query = Request.current.queryParams[Query]
    query.a + query.b
  }
}
