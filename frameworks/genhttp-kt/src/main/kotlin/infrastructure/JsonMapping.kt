package genhttp.infrastructure

import org.genhttp.modules.conversion.serializers.json.JsonFormat

import tools.jackson.databind.json.JsonMapper

object JsonMapping {

    /**
     * A mapper using the same defaults as GenHTTP uses to (de-)serialize request and response bodies.
     */
    val mapper: JsonMapper = JsonFormat.getDefaultOptions().build()

}
