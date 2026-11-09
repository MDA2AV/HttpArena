package baseline

import klite.annotations.GET
import klite.annotations.POST
import klite.annotations.QueryParam

class BaselineRoutes {
  @GET fun sum(@QueryParam a: Long, @QueryParam b: Long) = a + b

  /** The plain-text body is parsed into a number by Klite's TextBodyParser */
  @POST fun sumWithBody(@QueryParam a: Long, @QueryParam b: Long, body: Long) = a + b + body
}
