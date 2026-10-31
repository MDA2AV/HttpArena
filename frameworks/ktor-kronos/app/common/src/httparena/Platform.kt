package httparena

// What the JVM entries get from the JVM: natively from posix, on the JVM from the JDK, through FFM where it has nothing.

expect fun env(name: String): String?

fun intEnv(name: String, default: Int): Int = env(name)?.toIntOrNull() ?: default

/**
 * The CPUs this process may run on, as the JVM's availableProcessors counts them: the affinity list, which a
 * container's cpuset narrows, and the online count when that cannot be read.
 */
fun availableProcessors(): Int {
    val status = readFile("/proc/self/status")?.decodeToString()
    val line = status?.lineSequence()?.firstOrNull { it.startsWith("Cpus_allowed_list:") }
        ?: return onlineProcessors()

    var count = 0
    for (range in line.substringAfter(':').trim().split(',')) {
        val bounds = range.split('-')
        val first = bounds[0].toIntOrNull() ?: continue
        val last = if (bounds.size > 1) bounds[1].toIntOrNull() ?: first else first
        count += last - first + 1
    }

    return if (count > 0) count else onlineProcessors()
}

/** The CPUs online, sysconf's count, whatever the affinity. */
expect fun onlineProcessors(): Int

expect fun fileExists(path: String): Boolean

/**
 * Whether the kernel can take over TLS records (kTLS), asked as kron's own entry asks: a socket that is not connected
 * takes the tls ULP only where the module is in (ENOTCONN), and refuses it with ENOENT where it is not. The ULP list
 * under /proc/sys/net cannot answer it in a container on its own network, which is how validate.sh runs one.
 */
expect fun kernelTlsAvailable(): Boolean

/** A file read whole, or null when it cannot be; /proc files report no size, so it reads until the end. */
expect fun readFile(path: String): ByteArray?
