import zio.*
import zio.http.*
import zio.json.*

import com.zaxxer.hikari.{HikariConfig, HikariDataSource}
import redis.clients.jedis.{JedisPool, JedisPoolConfig}

import java.io.File
import java.nio.charset.StandardCharsets
import java.nio.file.{Files, Paths}
import java.sql.ResultSet

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

/** The crud write body. Every field is optional: the profile posts a subset and the
  * handler falls back for the rest.
  */
final case class CrudBody(
  id: Option[Long],
  name: Option[String],
  category: Option[String],
  price: Option[Long],
  quantity: Option[Long],
)
object CrudBody:
  given JsonDecoder[CrudBody] = DeriveJsonDecoder.gen[CrudBody]

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

  // ── Postgres ────────────────────────────────────────────────────────────────
  // The JDBC driver blocks, so every query below runs on ZIO's blocking pool and the
  // server's event loops stay free. The pool is sized to the cores the container gets.
  private val pool: Option[HikariDataSource] =
    sys.env.get("DATABASE_URL").filter(_.nonEmpty).flatMap { url =>
      try
        val cfg = new HikariConfig()
        // DATABASE_URL arrives as postgres://user:pass@host:port/db, which JDBC does not take
        val uri  = new java.net.URI(url)
        val info = Option(uri.getUserInfo).getOrElse("").split(":", 2)
        cfg.setJdbcUrl(s"jdbc:postgresql://${uri.getHost}:${uri.getPort}${uri.getPath}")
        if info.length == 2 then
          cfg.setUsername(info(0))
          cfg.setPassword(info(1))
        cfg.setMaximumPoolSize(
          math.max(8, java.lang.Runtime.getRuntime.availableProcessors())
        )
        cfg.setPoolName("httparena")
        Some(new HikariDataSource(cfg))
      catch case _: Throwable => None
    }

  // ── Redis ───────────────────────────────────────────────────────────────────
  // crud's cache-aside, and the one profile the harness provides Redis for.
  private val jedis: Option[JedisPool] =
    sys.env.get("REDIS_URL").filter(_.nonEmpty).flatMap { url =>
      try
        val cfg = new JedisPoolConfig()
        cfg.setMaxTotal(math.max(8, java.lang.Runtime.getRuntime.availableProcessors()))
        Some(new JedisPool(cfg, new java.net.URI(url)))
      catch case _: Throwable => None
    }

  /** The profile reads and writes the same ids, so a long TTL would answer from a copy
    * the writes have already moved past.
    */
  private val CrudTtlMs = 200L

  private def query[A](sql: String, args: Seq[Any])(read: ResultSet => A): Task[List[A]] =
    ZIO.attemptBlocking {
      val ds = pool.get
      val c  = ds.getConnection
      try
        val st = c.prepareStatement(sql)
        try
          args.zipWithIndex.foreach { case (a, i) => st.setObject(i + 1, a) }
          val rs  = st.executeQuery()
          val buf = List.newBuilder[A]
          while rs.next() do buf += read(rs)
          buf.result()
        finally st.close()
      finally c.close()
    }

  private def update(sql: String, args: Seq[Any]): Task[Int] =
    ZIO.attemptBlocking {
      val ds = pool.get
      val c  = ds.getConnection
      try
        val st = c.prepareStatement(sql)
        try
          args.zipWithIndex.foreach { case (a, i) => st.setObject(i + 1, a) }
          st.executeUpdate()
        finally st.close()
      finally c.close()
    }

  private val ItemColumns =
    "id, name, category, price, quantity, active, tags, rating_score, rating_count"

  /** The row shape every item-returning endpoint answers with. */
  private def itemJson(rs: ResultSet): String =
    val tags = Option(rs.getString("tags")).getOrElse("[]")
    s"""{"id":${rs.getLong("id")},"name":${rs.getString("name").toJson},"category":${rs
        .getString("category")
        .toJson},"price":${rs.getLong("price")},"quantity":${rs.getLong(
        "quantity"
      )},"active":${rs.getBoolean("active")},"tags":$tags,"rating":{"score":${rs.getLong(
        "rating_score"
      )},"count":${rs.getLong("rating_count")}}}"""

  private def jsonResponse(body: String, status: Status = Status.Ok): Response =
    Response(status = status, body = Body.fromString(body))
      .addHeader(Header.ContentType(MediaType.application.json))

  private def dbError(message: String): Response =
    jsonResponse(s"""{"error":"$message"}""", Status.InternalServerError)

  private def intQuery(request: Request, name: String, fallback: Int): Int =
    request.url.queryParams.getAll(name).headOption.flatMap(parseLong).map(_.toInt).getOrElse(fallback)

  // ── static ──────────────────────────────────────────────────────────────────
  // Bodies are read from disk on every request, which the static profiles require in
  // every mode. Only the content type is decided from the name.
  private val StaticRoot = "/data/static"

  private def contentType(name: String): String =
    name.lastIndexOf('.') match
      case -1 => "application/octet-stream"
      case i =>
        name.substring(i) match
          case ".css"   => "text/css"
          case ".js"    => "application/javascript"
          case ".html"  => "text/html"
          case ".woff2" => "font/woff2"
          case ".svg"   => "image/svg+xml"
          case ".webp"  => "image/webp"
          case ".json"  => "application/json"
          case _        => "application/octet-stream"

  private def staticFile(name: String, request: Request): Task[Response] =
    if name.contains("/") || name.contains("..") then ZIO.succeed(Response.status(Status.NotFound))
    else
      ZIO.attemptBlocking {
        val base = s"$StaticRoot/$name"
        if !new File(base).isFile then Response.status(Status.NotFound)
        else
          val accept = request.headers.get("accept-encoding").getOrElse("")
          val (path, encoding) =
            if accept.contains("br") && new File(s"$base.br").isFile then (s"$base.br", Some("br"))
            else if accept.contains("gzip") && new File(s"$base.gz").isFile then (s"$base.gz", Some("gzip"))
            else (base, None)
          val bytes = Files.readAllBytes(Paths.get(path))
          val base0 = Response(body = Body.fromChunk(Chunk.fromArray(bytes)))
            .addHeader("content-type", contentType(name))
          encoding.fold(base0)(e => base0.addHeader("content-encoding", e))
      }.catchAll(_ => ZIO.succeed(Response.status(Status.NotFound)))

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
    Method.GET / "baseline2" -> handler { (request: Request) =>
      Response.text(querySum(request).toString)
    },
    Method.GET / "static" / string("name") -> handler { (name: String, request: Request) =>
      staticFile(name, request).orDie
    },
    Method.GET / "async-db" -> handler { (request: Request) =>
      if pool.isEmpty then ZIO.succeed(jsonResponse("""{"items":[],"count":0}"""))
      else
        val min   = intQuery(request, "min", 10)
        val max   = intQuery(request, "max", 50)
        val limit = math.max(1, math.min(50, intQuery(request, "limit", 50)))
        query(s"SELECT $ItemColumns FROM items WHERE price BETWEEN ? AND ? LIMIT ?", Seq(min, max, limit))(itemJson)
          .map(items => jsonResponse(s"""{"items":[${items.mkString(",")}],"count":${items.length}}"""))
          .catchAll(_ => ZIO.succeed(jsonResponse("""{"items":[],"count":0}""")))
    },
    Method.GET / "crud" / "items" -> handler { (request: Request) =>
      if pool.isEmpty then ZIO.succeed(dbError("DB not available"))
      else
        val category = request.url.queryParams.getAll("category").headOption.getOrElse("electronics")
        val page     = math.max(1, intQuery(request, "page", 1))
        val limit    = math.max(1, math.min(50, intQuery(request, "limit", 10)))
        query(
          s"SELECT $ItemColumns FROM items WHERE category = ? ORDER BY id LIMIT ? OFFSET ?",
          Seq(category, limit, (page - 1) * limit)
        )(itemJson)
          .map(items =>
            jsonResponse(
              s"""{"items":[${items.mkString(",")}],"total":${items.length},"page":$page,"limit":$limit}"""
            )
          )
          .catchAll(_ => ZIO.succeed(dbError("query failed")))
    },
    Method.POST / "crud" / "items" -> handler { (request: Request) =>
      if pool.isEmpty then ZIO.succeed(dbError("DB not available"))
      else
        request.body.asString.orDie.flatMap { raw =>
          val body     = raw.fromJson[CrudBody].toOption
          val id       = body.flatMap(_.id).getOrElse(0L)
          val name     = body.flatMap(_.name).getOrElse("New Product")
          val category = body.flatMap(_.category).getOrElse("test")
          val price    = body.flatMap(_.price).getOrElse(0L)
          val quantity = body.flatMap(_.quantity).getOrElse(0L)
          update(
            "INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) " +
              "VALUES (?, ?, ?, ?, ?, true, '[\"bench\"]', 0, 0) " +
              "ON CONFLICT (id) DO UPDATE SET name = ?, price = ?, quantity = ?",
            Seq(id, name, category, price, quantity, name, price, quantity)
          ).map(_ =>
            jsonResponse(
              s"""{"id":$id,"name":${name.toJson},"category":${category.toJson},"price":$price,"quantity":$quantity}""",
              Status.Created
            )
          ).catchAll(_ => ZIO.succeed(dbError("insert failed")))
        }
    },
    // Cache-aside on Redis where the harness provides it - crud is the one profile
    // that does.
    Method.GET / "crud" / "items" / long("id") -> handler { (id: Long, _: Request) =>
      if pool.isEmpty then ZIO.succeed(dbError("DB not available"))
      else
        val key = s"crud:$id"
        val cached = ZIO
          .attemptBlocking(jedis.flatMap(p => Option(p.getResource).flatMap { c =>
            try Option(c.get(key))
            finally c.close()
          }))
          .catchAll(_ => ZIO.succeed(None))
        cached.flatMap {
          case Some(hit) =>
            ZIO.succeed(jsonResponse(hit).addHeader("x-cache", "HIT"))
          case None =>
            query(s"SELECT $ItemColumns FROM items WHERE id = ? LIMIT 1", Seq(id))(itemJson).flatMap {
              case Nil => ZIO.succeed(Response.status(Status.NotFound))
              case body :: _ =>
                ZIO
                  .attemptBlocking(jedis.foreach { p =>
                    val c = p.getResource
                    try c.psetex(key, CrudTtlMs, body)
                    finally c.close()
                  })
                  .ignore
                  .as(jsonResponse(body).addHeader("x-cache", "MISS"))
            }.catchAll(_ => ZIO.succeed(dbError("query failed")))
        }
    },
    Method.PUT / "crud" / "items" / long("id") -> handler { (id: Long, request: Request) =>
      if pool.isEmpty then ZIO.succeed(dbError("DB not available"))
      else
        request.body.asString.orDie.flatMap { raw =>
          val body     = raw.fromJson[CrudBody].toOption
          val name     = body.flatMap(_.name).getOrElse("Updated")
          val price    = body.flatMap(_.price).getOrElse(0L)
          val quantity = body.flatMap(_.quantity).getOrElse(0L)
          update("UPDATE items SET name = ?, price = ?, quantity = ? WHERE id = ?", Seq(name, price, quantity, id))
            .flatMap { rows =>
              if rows == 0 then ZIO.succeed(Response.status(Status.NotFound))
              else
                ZIO
                  .attemptBlocking(jedis.foreach { p =>
                    val c = p.getResource
                    try c.del(s"crud:$id")
                    finally c.close()
                  })
                  .ignore
                  .as(
                    jsonResponse(
                      s"""{"id":$id,"name":${name.toJson},"price":$price,"quantity":$quantity}"""
                    )
                  )
            }
            .catchAll(_ => ZIO.succeed(dbError("update failed")))
        }
    },
  )

  private val config =
    Server.Config.default
      .port(8080)
      // gzip is the server's own response compression, Netty's compressor with its defaults
      .responseCompression()
      // small bodies stay aggregated, /upload streams instead of buffering 20 MB
      .hybridRequestStreaming(1024 * 100)

  // json-tls and static-tls on 8081, the same routes behind TLS. The harness only mounts
  // /certs for the TLS profiles, so without them the second server is not started.
  private val CertPath = "/certs/server.crt"
  private val KeyPath  = "/certs/server.key"

  private val tlsConfig: Option[Server.Config] =
    if new File(CertPath).isFile && new File(KeyPath).isFile then
      Some(
        Server.Config.default
          .port(8081)
          .responseCompression()
          .hybridRequestStreaming(1024 * 100)
          .ssl(SSLConfig.fromFile(CertPath, KeyPath))
      )
    else None

  def run: ZIO[Any, Throwable, Nothing] =
    val plain = Server.serve(routes).provide(ZLayer.succeed(config), Server.live)
    tlsConfig match
      case None      => plain
      case Some(tls) =>
        // Both servers run for the life of the process; neither ever completes, so the
        // race only settles if one fails, which takes the process down rather than
        // leaving a port silently unserved.
        plain.raceFirst(Server.serve(routes).provide(ZLayer.succeed(tls), Server.live))
