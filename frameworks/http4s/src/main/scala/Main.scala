import cats.effect.{IO, IOApp}
import cats.syntax.all.*
import com.comcast.ip4s.{Host, Port}
import fs2.io.net.Network
import fs2.io.net.tls.TLSContext
import io.circe.{Json, JsonObject, parser}
import org.http4s.circe.*
import org.http4s.dsl.io.*
import org.http4s.ember.server.EmberServerBuilder
import org.http4s.server.middleware.GZip
import org.http4s.{HttpRoutes, Request}

import java.io.{File, FileInputStream}
import java.security.cert.{Certificate, CertificateFactory}
import java.security.spec.PKCS8EncodedKeySpec
import java.security.{KeyFactory, KeyStore}
import java.util.Base64
import javax.net.ssl.{KeyManagerFactory, SSLContext}

import scala.io.Source
import scala.util.Using
import scala.jdk.CollectionConverters.*

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

  // json-tls needs HTTP/1.1 over TLS on 8081. The harness mounts PEMs and Ember
  // wants a TLSContext, so the pair is converted in-process. Plain JDK crypto
  // rather than java.security.PEMDecoder, which is still a preview API here.
  private def sslContext: Option[SSLContext] =
    val cert = File("/certs/server.crt")
    val key = File("/certs/server.key")
    Option.when(cert.exists() && key.exists()):
      val chain = Using.resource(FileInputStream(cert)): in =>
        CertificateFactory
          .getInstance("X.509")
          .generateCertificates(in)
          .asScala
          .toArray[Certificate]
      val der = Base64.getDecoder.decode(
        Source
          .fromFile(key)
          .mkString
          .replaceAll("-----(BEGIN|END) PRIVATE KEY-----", "")
          .replaceAll("\\s", "")
      )
      val privateKey = KeyFactory.getInstance("RSA").generatePrivate(PKCS8EncodedKeySpec(der))
      val password = Array.empty[Char]
      val store = KeyStore.getInstance("PKCS12")
      store.load(null, password)
      store.setKeyEntry("server", privateKey, password, chain)
      val kmf = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm)
      kmf.init(store, password)
      val ctx = SSLContext.getInstance("TLS")
      ctx.init(kmf.getKeyManagers, null, null)
      ctx

  // One builder definition, so both ports serve the identical routes.
  private def server(port: Int, tls: Option[TLSContext[IO]]) =
    val base = EmberServerBuilder
      .default[IO]
      .withHost(Host.fromString("0.0.0.0").get)
      .withPort(Port.fromInt(port).get)
      .withHttpApp(GZip(routes).orNotFound)
      .withMaxConnections(16384)
    tls.fold(base)(base.withTLS(_)).build

  def run: IO[Unit] =
    sslContext match
      case Some(ctx) =>
        val tls = Network[IO].tlsContext.fromSSLContext(ctx)
        (server(8080, None), server(8081, Some(tls))).parTupled.useForever
      case None =>
        server(8080, None).useForever
