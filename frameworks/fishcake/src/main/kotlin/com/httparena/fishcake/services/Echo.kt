package com.httparena.fishcake.services

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.codegreen.modules.reflection.Method
import org.codegreen.modules.webservices.ResourceMethod
import java.io.InputStream

/**
 * `POST /echo` returns the request body back verbatim.
 *
 * The body is streamed straight off the connection, so it is read on [Dispatchers.IO]
 * rather than the engine's event loop — reading it on the event loop would deadlock, since
 * that thread is what delivers the bytes. It is collected before replying because the
 * response cannot be framed until its length is known, which is also what makes a chunked
 * request work.
 */
class Echo {

    @ResourceMethod(Method.Post)
    suspend fun compute(input: InputStream): ByteArray = withContext(Dispatchers.IO) {
        input.readBytes()
    }
}
