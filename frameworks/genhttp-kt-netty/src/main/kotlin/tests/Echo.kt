package genhttp.tests

import org.genhttp.modules.reflection.Method
import org.genhttp.modules.webservices.ResourceMethod

import java.io.InputStream

class Echo {

    @ResourceMethod(Method.Post)
    fun echo(input: InputStream): InputStream = input

}
