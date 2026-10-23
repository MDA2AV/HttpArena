package genhttp.tests

import org.genhttp.modules.reflection.FromBody
import org.genhttp.modules.reflection.Method
import org.genhttp.modules.webservices.ResourceMethod

class Baseline {

    @ResourceMethod
    fun sum(a: Int, b: Int): Int = a + b

    @ResourceMethod(Method.Post)
    fun sum(a: Int, b: Int, @FromBody c: Int): Int = a + b + c

}
