import baseline.BaselineRoutes
import delay.DelayRoutes
import fortunes.FortuneRoutes
import gg.jte.ContentType
import gg.jte.TemplateEngine
import items.ItemRoutes
import klite.Config
import klite.Server
import klite.annotations.annotated
import klite.jdbc.DBModule
import klite.jdbc.PooledDataSource
import klite.jdbc.RequestTransactionHandler
import klite.jdbc.initHerokuDB
import klite.json.JsonBody
import klite.register

fun main() {
  // No decorators means no RequestLogger: request logging is disabled for the benchmark
  Server(decorators = emptyList()).apply {
    use<JsonBody>()
    register(TemplateEngine.createPrecompiled(ContentType.Html))

    context("/baseline11") { annotated<BaselineRoutes>() }
    context("/pipeline") { get { "ok" } }
    context("/delay") { annotated<DelayRoutes>() }

    // the database is only provided to the profiles that use it
    if (Config.optional("DATABASE_URL") != null) {
      initHerokuDB(suffix = "")
      use(DBModule(PooledDataSource(maxSize = Config.optional("DATABASE_MAX_CONN", "256").toInt())))

      context("/async-db") {
        useOnly<JsonBody>()
        use<RequestTransactionHandler>()
        annotated<ItemRoutes>()
      }

      context("/fortunes") {
        use<RequestTransactionHandler>()
        annotated<FortuneRoutes>()
      }
    }

    start()
  }
}
