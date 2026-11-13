package edixoi

import kotlin.native.runtime.GC
import kotlin.native.runtime.NativeRuntimeApi

@OptIn(NativeRuntimeApi::class)
fun main() {
    // Kotlin/Native's collector starts from a heap sized for a phone and runs every few megabytes allocated, each
    // run stopping every reactor at a safepoint. From a 64 MiB floor it runs far less often; the JVM starts from a
    // much larger heap anyway.
    val heapMb = intEnv("EDIXOI_GC_MIN_HEAP_MB", 64)
    GC.minHeapBytes = heapMb.toLong() shl 20
    serve("Kotlin/Native, GC heap floor $heapMb MiB")
}
