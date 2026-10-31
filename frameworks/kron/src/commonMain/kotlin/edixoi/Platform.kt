package edixoi

// What the JVM gave edixoi-kt for free: natively from posix, on the JVM from the JDK, through FFM where it has nothing.

expect fun env(name: String): String?

expect fun fileExists(path: String): Boolean

expect fun printErr(message: String)

/** The CPUs online, whatever the affinity. */
expect fun onlineProcessors(): Int

/**
 * Whether the kernel can take TLS records. Setting the tls ULP on a socket that is not connected asks the kernel
 * itself: ENOTCONN once the module is in, ENOENT when it is not. The ULP list under /proc/sys/net cannot answer it,
 * as it exists only in the host's network namespace and a container on its own network does not see it.
 */
expect fun kernelTlsAvailable(): Boolean

/** The whole file at [path], or null when it cannot be opened or read. */
expect fun readFile(path: String): ByteArray?

/** [value] as the eight bytes at [index], little-endian and wherever they fall: Kotlin/Native's setLongAt. */
expect fun ByteArray.putLong(index: Int, value: Long)

/** [value] as the two bytes at [index], little-endian: Kotlin/Native's setShortAt. */
expect fun ByteArray.putShort(index: Int, value: Short)

/**
 * The CPUs this process may run on, as the JVM's availableProcessors counts them: the affinity list, which a
 * container's cpuset narrows, and the online count when that cannot be read.
 */
fun availableProcessors(): Int {
    val status = readFile("/proc/self/status")?.decodeToString()
    val line = status?.lineSequence()?.firstOrNull { it.startsWith("Cpus_allowed_list:") }
    if (line == null) {
        return onlineProcessors()
    }

    var count = 0
    for (range in line.substringAfter(':').trim().split(',')) {
        val bounds = range.split('-')
        val first = bounds[0].toIntOrNull() ?: continue
        val last = if (bounds.size > 1) bounds[1].toIntOrNull() ?: first else first
        count += last - first + 1
    }

    return if (count > 0) count else onlineProcessors()
}

/** A growing byte buffer, for what java.io.ByteArrayOutputStream did in the dataset reader. */
class Bytes {
    private var bytes = ByteArray(64)
    private var length = 0

    fun write(byte: Int) {
        if (length == bytes.size) {
            bytes = bytes.copyOf(bytes.size * 2)
        }

        bytes[length] = byte.toByte()
        length++
    }

    fun write(source: ByteArray) {
        for (b in source) {
            write(b.toInt())
        }
    }

    fun decode(): String = bytes.decodeToString(0, length)
}
