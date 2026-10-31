package httparena

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.alloc
import kotlinx.cinterop.memScoped
import kotlinx.cinterop.pointed
import kotlinx.cinterop.ptr
import kotlinx.cinterop.staticCFunction
import kotlinx.cinterop.toKString
import kotlinx.cinterop.value
import platform.posix.closedir
import platform.posix.opendir
import platform.posix.pthread_create
import platform.posix.pthread_detach
import platform.posix.pthread_tVar
import platform.posix.readdir
import platform.posix.usleep
import kotlin.native.runtime.GC
import kotlin.native.runtime.NativeRuntimeApi
import kotlin.time.TimeSource

// DIAGNOSTICS, temporary: where the CPU goes on the arena box. Every 5 s, each thread group's share of a CPU (from
// /proc/self/task; the reactors are the binary's own name), and the collector's runs in that window - how long they
// held the reactors stopped, the longest such pause, and the heap they left.
@OptIn(ExperimentalForeignApi::class)
fun startDiagnostics() {
    memScoped {
        val thread = alloc<pthread_tVar>()
        pthread_create(thread.ptr, null, staticCFunction { _ -> diagnosticsLoop(); null }, null)
        pthread_detach(thread.value)
    }
}

@OptIn(NativeRuntimeApi::class, ExperimentalStdlibApi::class)
private fun diagnosticsLoop() {
    val clock = TimeSource.Monotonic
    var last = sampleThreads()
    var lastAt = clock.markNow()
    var seenEpoch = GC.lastGCInfo?.epoch ?: 0L
    var windowEpoch = seenEpoch
    var seen = 0
    var pausedNs = 0L
    var maxPauseNs = 0L
    var runningNs = 0L
    var heapAfter = 0L
    while (true) {
        usleep(10_000u)
        val info = GC.lastGCInfo
        if (info != null && info.epoch != seenEpoch) {
            seenEpoch = info.epoch
            val first = info.firstPauseEndTimeNs - info.firstPauseRequestTimeNs
            val second = (info.secondPauseEndTimeNs ?: 0L) - (info.secondPauseRequestTimeNs ?: 0L)
            pausedNs += first + second
            maxPauseNs = maxOf(maxPauseNs, first, second)
            runningNs += info.endTimeNs - info.startTimeNs
            heapAfter = info.memoryUsageAfter.values.sumOf { it.totalObjectsSizeBytes }
            seen++
        }

        val elapsed = lastAt.elapsedNow()
        if (elapsed.inWholeMilliseconds < 5_000) {
            continue
        }

        val now = sampleThreads()
        val seconds = elapsed.inWholeMicroseconds / 1e6
        val groups = HashMap<String, Long>()
        for ((tid, value) in now) {
            groups[value.first] = (groups[value.first] ?: 0L) + value.second - (last[tid]?.second ?: 0L)
        }
        val cpu = groups.entries.filter { it.value > 0 }.sortedByDescending { it.value }
            .joinToString(" | ") { "${it.key} ${(it.value / seconds).toInt()}%" }
        println(
            "[cpu] $cpu || gc ${seenEpoch - windowEpoch}x ($seen seen), paused ${pausedNs / 1_000_000} ms " +
                "(max ${maxPauseNs / 1_000_000}), running ${runningNs / 1_000_000} ms, heap after ${heapAfter shr 20} MiB"
        )
        last = now
        lastAt = clock.markNow()
        windowEpoch = seenEpoch
        seen = 0
        pausedNs = 0
        maxPauseNs = 0
        runningNs = 0
    }
}

// Each thread's name and its user + system CPU ticks (1/100 s), by thread id.
@OptIn(ExperimentalForeignApi::class)
private fun sampleThreads(): Map<String, Pair<String, Long>> {
    val out = HashMap<String, Pair<String, Long>>()
    val dir = opendir("/proc/self/task") ?: return out
    try {
        while (true) {
            val entry = readdir(dir) ?: break
            val tid = entry.pointed.d_name.toKString()
            if (tid.startsWith(".")) {
                continue
            }

            val stat = readFile("/proc/self/task/$tid/stat")?.decodeToString() ?: continue
            val close = stat.lastIndexOf(')')
            val name = stat.substring(stat.indexOf('(') + 1, close).replace(Regex("[#-]?\\d+$"), "")
            val fields = stat.substring(close + 2).split(' ')
            out[tid] = name to (fields[11].toLong() + fields[12].toLong())
        }
    } finally {
        closedir(dir)
    }

    return out
}
