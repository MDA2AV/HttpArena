package delay

import klite.annotations.GET
import klite.annotations.PathParam
import klite.sleep
import kotlin.time.Duration.Companion.milliseconds

class DelayRoutes {
  /** Klite runs every request on its own virtual thread, so sleeping parks it rather than blocking a carrier thread */
  @GET("/:ms") fun delay(@PathParam ms: Long): Long {
    sleep(ms.milliseconds)
    return ms
  }
}
