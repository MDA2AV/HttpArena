package fortunes

import gg.jte.TemplateEngine
import gg.jte.output.StringOutput
import klite.HttpExchange
import klite.MimeTypes
import klite.StatusCode.Companion.OK
import klite.annotations.GET
import klite.jdbc.select
import javax.sql.DataSource

data class Fortune(val id: Int, val message: String)

class FortuneRepository(private val db: DataSource) {
  fun list() = db.select<Fortune>("fortune")
}

class FortuneRoutes(private val fortunes: FortuneRepository, private val templates: TemplateEngine) {
  /** Klite has no template engine of its own; its docs suggest calling one and sending the html */
  @GET fun list(e: HttpExchange) {
    val sorted = (fortunes.list() + Fortune(0, "Additional fortune added at request time.")).sortedBy { it.message }
    val html = StringOutput().also { templates.render("fortunes.kte", sorted, it) }
    e.send(OK, html.toString(), MimeTypes.html)
  }
}
