package httparena

import io.ktor.server.application.install
import io.ktor.server.plugins.compression.Compression
import io.ktor.server.plugins.compression.gzip
import io.ktor.server.routing.Route
import java.io.File
import java.lang.management.ManagementFactory

fun main() {
    cpuReport()
    serve { "JVM ${Runtime.version()}" }
}

actual fun Route.installCompression() {
    install(Compression) {
        gzip()
    }
}

// DIAGNOSTICS, temporary: where the CPU goes on the arena box. Every 5 s, each thread group's share of a CPU (from
// /proc/self/task, so the JVM's own GC and JIT threads count too), the collections in that window and the heap.
private fun cpuReport() {
    fun sample(): Map<String, Pair<String, Long>> {
        val out = HashMap<String, Pair<String, Long>>()
        File("/proc/self/task").listFiles()?.forEach { task ->
            try {
                val stat = File(task, "stat").readText()
                val name = stat.substring(stat.indexOf('(') + 1, stat.lastIndexOf(')'))
                val fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ')
                out[task.name] = name.replace(Regex("[#-]?\\d+$"), "") to fields[11].toLong() + fields[12].toLong()
            } catch (_: Exception) {
            }
        }
        return out
    }

    Thread({
        val collectors = ManagementFactory.getGarbageCollectorMXBeans()
        var last = sample()
        var lastAt = System.nanoTime()
        var lastGcCount = collectors.sumOf { it.collectionCount }
        var lastGcMs = collectors.sumOf { it.collectionTime }
        while (true) {
            Thread.sleep(5_000)
            val now = sample()
            val at = System.nanoTime()
            val seconds = (at - lastAt) / 1e9
            val groups = HashMap<String, Long>()
            for ((tid, value) in now) {
                groups.merge(value.first, value.second - (last[tid]?.second ?: 0L), Long::plus)
            }
            val gcCount = collectors.sumOf { it.collectionCount }
            val gcMs = collectors.sumOf { it.collectionTime }
            val runtime = Runtime.getRuntime()
            val usedMb = (runtime.totalMemory() - runtime.freeMemory()) shr 20
            val cpu = groups.entries.filter { it.value > 0 }.sortedByDescending { it.value }
                .joinToString(" | ") { "${it.key} ${(it.value / seconds).toInt()}%" }
            println("[cpu] $cpu || gc ${gcCount - lastGcCount}x ${gcMs - lastGcMs} ms, heap $usedMb/${runtime.totalMemory() shr 20} MiB")
            last = now
            lastAt = at
            lastGcCount = gcCount
            lastGcMs = gcMs
        }
    }, "cpu-report").apply { isDaemon = true }.start()
}
