package com.httparena.fishcake.services

import org.codegreen.modules.reflection.FromBody
import org.codegreen.modules.reflection.Method
import org.codegreen.modules.webservices.ResourceMethod

/**
 * `GET /baselineXX?a=&b=` sums two query values; the `POST` variant adds a third value read
 * directly from the request body. The two overloads share the route, split by HTTP verb.
 */
class Baseline {

    @ResourceMethod
    fun sum(a: Int, b: Int): Int = a + b

    @ResourceMethod(Method.Post)
    fun sum(a: Int, b: Int, @FromBody c: Int): Int = a + b + c
}
