import cats.effect.{IO, IOApp}
import com.comcast.ip4s.{Host, Port}
import io.circe.{Json, JsonObject, parser}
import org.http4s.circe.*
import org.http4s.dsl.io.*
import org.http4s.ember.server.EmberServerBuilder
import org.http4s.server.middleware.GZip
import org.http4s.{HttpRoutes, Request}

import scala.io.Source
import scala.util.Using

object Main extends IOApp.Simple:

  private val dataset: Vector[JsonObject] =
    val path = sys.env.getOrElse("DATASET_PATH", "/data/dataset.json")
    Using(Source.fromFile(path))(_.mkString).toOption
      .flatMap(parser.parse(_).toOption)
      .flatMap(_.asArray)
      .map(_.flatMap(_.asObject))
      .getOrElse(Vector.empty)

  private object Multiplier extends OptionalQueryParamDecoderMatcher[Long]("m")

  private def querySum(request: Request[IO]): Long =
    request.uri.query.params.values.flatMap(_.trim.toLongOption).sum

  private def field(item: JsonObject, name: String): Long =
    item(name).flatMap(_.asNumber).flatMap(_.toLong).getOrElse(0L)

  private def payload(count: Int, m: Long): Json =
    val take = math.max(0, math.min(count, dataset.size))
    val items = dataset.take(take).map { item =>
      Json.fromJsonObject(item.add("total", Json.fromLong(field(item, "price") * field(item, "quantity") * m)))
    }
    Json.obj("items" -> Json.fromValues(items), "count" -> Json.fromInt(take))

  private val routes = HttpRoutes.of[IO] {
    case GET -> Root / "pipeline" =>
      Ok("ok")

    case request @ GET -> Root / "baseline11" =>
      Ok(querySum(request).toString)

    case request @ POST -> Root / "baseline11" =>
      request.as[String].flatMap { body =>
        Ok((querySum(request) + body.trim.toLongOption.getOrElse(0L)).toString)
      }

    case GET -> Root / "json" / IntVar(count) :? Multiplier(m) =>
      Ok(payload(count, m.getOrElse(1L)))

    case request @ POST -> Root / "upload" =>
      request.body.chunks
        .fold(0L)((size, chunk) => size + chunk.size)
        .compile
        .lastOrError
        .flatMap(size => Ok(size.toString))
  }

  def run: IO[Unit] =
    EmberServerBuilder
      .default[IO]
      .withHost(Host.fromString("0.0.0.0").get)
      .withPort(Port.fromInt(8080).get)
      .withHttpApp(GZip(routes).orNotFound)
      .withMaxConnections(16384)
      .build
      .useForever
