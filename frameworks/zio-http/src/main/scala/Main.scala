import zio.*
import zio.http.*
import zio.json.*

import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Paths}

final case class Rating(score: Long, count: Long)
object Rating:
  given JsonDecoder[Rating] = DeriveJsonDecoder.gen[Rating]
  given JsonEncoder[Rating] = DeriveJsonEncoder.gen[Rating]

final case class Item(
  id: Long,
  name: String,
  category: String,
  price: Long,
  quantity: Long,
  active: Boolean,
  tags: List[String],
  rating: Rating,
)
object Item:
  given JsonDecoder[Item] = DeriveJsonDecoder.gen[Item]

/** A dataset item with the computed `total` appended, which is what /json returns. */
final case class PricedItem(
  id: Long,
  name: String,
  category: String,
  price: Long,
  quantity: Long,
  active: Boolean,
  tags: List[String],
  rating: Rating,
  total: Long,
)
object PricedItem:
  given JsonEncoder[PricedItem] = DeriveJsonEncoder.gen[PricedItem]

final case class Payload(items: List[PricedItem], count: Int)
object Payload:
  given JsonEncoder[Payload] = DeriveJsonEncoder.gen[Payload]

object Main extends ZIOAppDefault:

  /** Read once at startup. A missing or unreadable file leaves the list empty. */
  private val dataset: Vector[Item] =
    val path = sys.env.getOrElse("DATASET_PATH", "/data/dataset.json")
    try
      val text = new String(Files.readAllBytes(Paths.get(path)), StandardCharsets.UTF_8)
      text.fromJson[List[Item]].map(_.toVector).getOrElse(Vector.empty)
    catch case _: Throwable => Vector.empty

  private def parseLong(s: String): Option[Long] =
    val t = s.trim
    if t.isEmpty then None
    else
      try Some(java.lang.Long.parseLong(t))
      catch case _: NumberFormatException => None

  private def querySum(request: Request): Long =
    var sum = 0L
    val values = request.url.queryParams.map.valuesIterator
    while values.hasNext do
      val chunk = values.next()
      var i     = 0
      while i < chunk.length do
        parseLong(chunk(i)).foreach(sum += _)
        i += 1
    sum

  private def payload(count: Int, m: Long): Payload =
    val take  = math.max(0, math.min(count, dataset.length))
    val items = dataset.iterator
      .take(take)
      .map { it =>
        PricedItem(
          it.id,
          it.name,
          it.category,
          it.price,
          it.quantity,
          it.active,
          it.tags,
          it.rating,
          it.price * it.quantity * m,
        )
      }
      .toList
    Payload(items, take)

  private val routes = Routes(
    Method.GET / "pipeline" -> handler(Response.text("ok")),
    Method.GET / "baseline11" -> handler { (request: Request) =>
      Response.text(querySum(request).toString)
    },
    Method.POST / "baseline11" -> handler { (request: Request) =>
      request.body.asString
        .map(body => Response.text((querySum(request) + parseLong(body).getOrElse(0L)).toString))
        .orDie
    },
    Method.GET / "json" / int("count") -> handler { (count: Int, request: Request) =>
      val m = request.url.queryParams.getAll("m").headOption.flatMap(parseLong).getOrElse(1L)
      Response.json(payload(count, m).toJson)
    },
    // Folded over the body stream, so the 20 MB upload is never held in one buffer.
    Method.POST / "upload" -> handler { (request: Request) =>
      request.body.asStream.chunks
        .runFold(0L)((size, chunk) => size + chunk.length)
        .map(size => Response.text(size.toString))
        .orDie
    },
  )

  private val config =
    Server.Config.default
      .port(8080)
      // gzip is the server's own response compression, Netty's compressor with its defaults
      .responseCompression()
      // small bodies stay aggregated, /upload streams instead of buffering 20 MB
      .hybridRequestStreaming(1024 * 100)

  def run: ZIO[Any, Throwable, Nothing] =
    Server.serve(routes).provide(ZLayer.succeed(config), Server.live)
