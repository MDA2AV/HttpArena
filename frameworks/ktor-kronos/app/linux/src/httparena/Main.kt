package httparena

import kotlin.native.runtime.GC
import kotlin.native.runtime.NativeRuntimeApi

@OptIn(NativeRuntimeApi::class)
fun main() = serve { reactors ->
    // Kotlin/Native's collector is not generational: it marks everything live on every run, stops every reactor to do
    // it, and puts allocating threads to sleep when it falls behind. Ktor allocates some sixty objects a request, and
    // a WebSocket connection keeps some 260 live, so a heap floor sized for a phone has it running back to back, the
    // reactors idle. 512 MiB per reactor keeps the runs few even with tens of thousands of connections held.
    val heapMb = intEnv("KRONOS_GC_MIN_HEAP_MB", 512 * reactors)
    GC.minHeapBytes = heapMb.toLong() shl 20
    "Kotlin/Native, GC heap floor $heapMb MiB"
}
