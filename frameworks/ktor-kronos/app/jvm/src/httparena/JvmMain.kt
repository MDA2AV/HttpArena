package httparena

import io.ktor.server.application.install
import io.ktor.server.plugins.compression.Compression
import io.ktor.server.routing.Route
import io.ktor.util.ContentEncoder
import io.ktor.util.GZipEncoder
import io.ktor.utils.io.ByteReadChannel
import io.ktor.utils.io.ByteWriteChannel
import java.io.File
import java.lang.management.ManagementFactory
import java.nio.file.Files
import java.nio.file.Path
import java.time.Duration
import jdk.jfr.Recording
import jdk.jfr.consumer.RecordingFile
import kotlin.coroutines.CoroutineContext
import kotlinx.coroutines.Dispatchers

fun main() {
    cpuReport()
    jfrReport()
    serve { "JVM ${Runtime.version()}" }
}

actual fun Route.installCompression() {
    install(Compression) {
        encoder(ReactorGzip)
    }
}

// Ktor's own gzip, its deflate coroutine run where the response is read - the reactor - rather than on
// Dispatchers.Default, where Compression's empty context sends it, every response then crossing threads and back.
private object ReactorGzip : ContentEncoder by GZipEncoder {
    override fun encode(source: ByteReadChannel, coroutineContext: CoroutineContext): ByteReadChannel =
        GZipEncoder.encode(source, coroutineContext + Dispatchers.Unconfined)

    override fun encode(source: ByteWriteChannel, coroutineContext: CoroutineContext): ByteWriteChannel =
        GZipEncoder.encode(source, coroutineContext + Dispatchers.Unconfined)
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

// DIAGNOSTICS, temporary: what the threads run, from Flight Recorder, every 10 s - samples in Java and in native
// code (a reactor waiting in io_uring_enter), the top frames by package and by method, contended monitors, long parks.
private fun jfrReport() {
    Thread({
        while (true) {
            try {
                val recording = Recording()
                recording.enable("jdk.ExecutionSample").withPeriod(Duration.ofMillis(10))
                recording.enable("jdk.NativeMethodSample").withPeriod(Duration.ofMillis(20))
                recording.enable("jdk.JavaMonitorEnter").withThreshold(Duration.ofNanos(20_000))
                recording.enable("jdk.ThreadPark").withThreshold(Duration.ofMillis(1))
                recording.start()
                Thread.sleep(10_000)
                recording.stop()
                val file = Files.createTempFile("diag", ".jfr")
                recording.dump(file)
                recording.close()
                summarize(file)
                Files.delete(file)
            } catch (e: Exception) {
                println("[jfr] failed: $e")
                Thread.sleep(10_000)
            }
        }
    }, "jfr-report").apply { isDaemon = true }.start()
}

private fun summarize(file: Path) {
    val methods = HashMap<String, Int>()
    val packages = HashMap<String, Int>()
    val monitors = HashMap<String, LongArray>()
    val parks = HashMap<String, Int>()
    var java = 0
    var native = 0
    RecordingFile(file).use { events ->
        while (events.hasMoreEvents()) {
            val event = events.readEvent()
            when (event.eventType.name) {
                "jdk.ExecutionSample" -> {
                    java++
                    val frame = event.stackTrace?.frames?.firstOrNull() ?: continue
                    val type = frame.method.type.name
                    methods.merge("$type.${frame.method.name}", 1, Int::plus)
                    val parts = type.split('.')
                    packages.merge(parts.take(if (type.startsWith("io.ktor.")) 3 else 2).joinToString("."), 1, Int::plus)
                }
                "jdk.NativeMethodSample" -> native++
                "jdk.JavaMonitorEnter" -> {
                    val totals = monitors.getOrPut(event.getClass("monitorClass")?.name ?: "?") { LongArray(2) }
                    totals[0]++
                    totals[1] += event.duration.toNanos()
                }
                "jdk.ThreadPark" -> {
                    val frame = event.stackTrace?.frames?.firstOrNull {
                        !it.method.type.name.startsWith("java.") && !it.method.type.name.startsWith("jdk.")
                    }
                    parks.merge(frame?.let { "${it.method.type.name}.${it.method.name}" } ?: "?", 1, Int::plus)
                }
            }
        }
    }
    fun share(n: Int) = if (java == 0) "0%" else "${n * 1000 / java / 10.0}%"
    println("[jfr] java $java, native $native || " +
        packages.entries.sortedByDescending { it.value }.take(10).joinToString(" | ") { "${it.key} ${share(it.value)}" })
    println("[jfr] hot " + methods.entries.sortedByDescending { it.value }.take(15).joinToString(" | ") { "${share(it.value)} ${it.key}" })
    if (monitors.isNotEmpty()) {
        println("[jfr] contended " + monitors.entries.sortedByDescending { it.value[1] }.take(5)
            .joinToString(" | ") { "${it.key} ${it.value[0]}x ${it.value[1] / 1_000_000} ms" })
    }
    if (parks.isNotEmpty()) {
        println("[jfr] parks " + parks.entries.sortedByDescending { it.value }.take(5).joinToString(" | ") { "${it.key} ${it.value}x" })
    }
}

