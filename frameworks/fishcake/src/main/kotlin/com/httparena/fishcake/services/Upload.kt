package com.httparena.fishcake.services

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.codegreen.modules.reflection.Method
import org.codegreen.modules.webservices.ResourceMethod
import java.io.InputStream

/**
 * `POST /upload` drains the request body stream and returns the number of bytes received.
 *
 * The body is streamed straight off the connection, so it is read on [Dispatchers.IO]
 * rather than the engine's event loop — reading it on the event loop would deadlock, since
 * that thread is what delivers the bytes.
 */
class Upload {

    @ResourceMethod(Method.Post)
    suspend fun compute(input: InputStream): Long = withContext(Dispatchers.IO) {
        val buffer = ByteArray(8192)
        var total = 0L
        while (true) {
            val read = input.read(buffer)
            if (read <= 0) break
            total += read
        }
        total
    }
}
