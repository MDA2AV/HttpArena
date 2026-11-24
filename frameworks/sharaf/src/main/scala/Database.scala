import java.net.URI

import com.zaxxer.hikari.{HikariConfig, HikariDataSource}

import ba.sake.squery.*
import ba.sake.squery.given
import ba.sake.squery.postgres.{*, given}
import ba.sake.squery.read.{*, given}
import ba.sake.squery.write.{*, given}

case class DbItem(
    id: Int,
    name: String,
    category: String,
    price: Long,
    quantity: Long,
    active: Boolean,
    tags: Vector[String],
    rating_score: Int,
    rating_count: Int
) derives SqlReadRow

case class Fortune(id: Int, message: String) derives SqlReadRow

final class Database private (dataSource: HikariDataSource, context: SqueryContext) {
  def items(min: Int, max: Int, limit: Int): Payload = {
    val result = context.run {
      sql"""
        SELECT id, name, category, price, quantity, active,
               ARRAY(SELECT jsonb_array_elements_text(tags)) AS tags,
               rating_score, rating_count
        FROM items
        WHERE price BETWEEN $min AND $max
        LIMIT ${math.min(math.max(limit, 1), 50)}
      """.readRows[DbItem]()
    }
    val items = result.map { row =>
      Item(
        row.id,
        row.name,
        row.category,
        row.price,
        row.quantity,
        row.active,
        row.tags,
        Rating(row.rating_score, row.rating_count)
      )
    }
    Payload(items, items.size)
  }

  def fortunes(): Seq[Fortune] = context.run {
    sql"SELECT id, message FROM fortune".readRows[Fortune]()
  }

  def close(): Unit = dataSource.close()
}

object Database {
  def fromEnvironment(): Option[Database] = {
    sys.env.get("DATABASE_URL").filter(_.nonEmpty).flatMap { url =>
      try {
        val dataSource = new HikariDataSource(hikariConfig(url))
        Some(new Database(dataSource, SqueryContext(dataSource)))
      } catch {
        case error: Throwable =>
          error.printStackTrace()
          None
      }
    }
  }

  private def hikariConfig(databaseUrl: String): HikariConfig = {
    val uri = URI.create(databaseUrl.replaceFirst("^postgres://", "postgresql://"))
    val port = if (uri.getPort > 0) uri.getPort else 5432
    val userInfo = Option(uri.getUserInfo).toSeq.flatMap(_.split(":", 2))
    val maximumPoolSize = sys.env.get("DATABASE_MAX_CONN").flatMap(_.toIntOption).getOrElse(64)
    val config = new HikariConfig()
    config.setJdbcUrl(s"jdbc:postgresql://${uri.getHost}:$port${uri.getPath}")
    config.setUsername(userInfo.headOption.getOrElse("bench"))
    config.setPassword(userInfo.drop(1).headOption.getOrElse(""))
    config.setMaximumPoolSize(maximumPoolSize)
    config.setMinimumIdle(math.min(10, maximumPoolSize))
    config.setReadOnly(true)
    config.setPoolName("httparena-squery")
    config
  }
}
