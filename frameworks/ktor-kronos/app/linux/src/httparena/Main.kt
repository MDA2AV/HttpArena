package httparena

import io.ktor.server.routing.Route
import kotlin.native.runtime.GC
import kotlin.native.runtime.NativeRuntimeApi

@OptIn(NativeRuntimeApi::class)
fun main() = serve { reactors ->
    // Kotlin/Native's collector is not generational: it marks everything live on every run, stops every reactor to do
    // it, and puts allocating threads to sleep when it falls behind. Ktor allocates some sixty objects a request, and
    // a WebSocket connection keeps some 260 live, so a heap floor sized for a phone has it running back to back, the
    // reactors idle - and one too high lets tens of GiB of garbage pile up for each run to sweep, the reactors as idle.
    // On the arena's 64 cores, 64 MiB per reactor served 3.5 times what 512 did.
    val heapMb = intEnv("KRONOS_GC_MIN_HEAP_MB", 64 * reactors)
    GC.minHeapBytes = heapMb.toLong() shl 20
    "Kotlin/Native, GC heap floor $heapMb MiB"
}

// Ktor's Compression plugin is JVM-only: natively the JSON goes out as it is.
actual fun Route.installCompression() {}
