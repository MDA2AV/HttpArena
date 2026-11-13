package genhttp.tests

import kotlinx.coroutines.delay

import org.genhttp.modules.webservices.ResourceMethod

/**
 * The async profile: hold the request for the requested number of milliseconds, then answer.
 *
 * `delay` suspends the coroutine instead of blocking a thread, so the number of waits in flight
 * is bounded by memory rather than by threads.
 */
class Delay {

    @ResourceMethod(path = ":ms")
    suspend fun wait(ms: Int): String {
        if (ms > 0) {
            delay(ms.toLong())
        }

        return ms.toString()
    }

}
