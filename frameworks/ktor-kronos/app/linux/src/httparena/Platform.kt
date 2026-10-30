package httparena

import kotlinx.cinterop.ExperimentalForeignApi
import kotlinx.cinterop.addressOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.toKString
import kotlinx.cinterop.usePinned
import platform.posix.AF_INET
import platform.posix.ENOTCONN
import platform.posix.F_OK
import platform.posix.IPPROTO_TCP
import platform.posix.O_CLOEXEC
import platform.posix.O_RDONLY
import platform.posix.SOCK_CLOEXEC
import platform.posix.SOCK_STREAM
import platform.posix._SC_NPROCESSORS_ONLN
import platform.posix.access
import platform.posix.close
import platform.posix.errno
import platform.posix.getenv
import platform.posix.open
import platform.posix.read
import platform.posix.setsockopt
import platform.posix.socket
import platform.posix.sysconf

// What the JVM entries get from the JVM, on Kotlin/Native.

@OptIn(ExperimentalForeignApi::class)
fun env(name: String): String? = getenv(name)?.toKString()

fun intEnv(name: String, default: Int): Int = env(name)?.toIntOrNull() ?: default

/**
 * The CPUs this process may run on, as the JVM's availableProcessors counts them: the affinity list, which a
 * container's cpuset narrows, and the online count when that cannot be read.
 */
fun availableProcessors(): Int {
    val status = readFile("/proc/self/status")?.decodeToString()
    val line = status?.lineSequence()?.firstOrNull { it.startsWith("Cpus_allowed_list:") }
        ?: return sysconf(_SC_NPROCESSORS_ONLN).toInt()

    var count = 0
    for (range in line.substringAfter(':').trim().split(',')) {
        val bounds = range.split('-')
        val first = bounds[0].toIntOrNull() ?: continue
        val last = if (bounds.size > 1) bounds[1].toIntOrNull() ?: first else first
        count += last - first + 1
    }

    return if (count > 0) count else sysconf(_SC_NPROCESSORS_ONLN).toInt()
}

fun fileExists(path: String): Boolean = access(path, F_OK) == 0

private const val TCP_ULP = 31

/**
 * Whether the kernel can take over TLS records (kTLS), asked as kron's own entry asks: a socket that is not connected
 * takes the tls ULP only where the module is in (ENOTCONN), and refuses it with ENOENT where it is not. The ULP list
 * under /proc/sys/net cannot answer it in a container on its own network, which is how validate.sh runs one.
 */
@OptIn(ExperimentalForeignApi::class)
fun kernelTlsAvailable(): Boolean {
    val fd = socket(AF_INET, SOCK_STREAM or SOCK_CLOEXEC, 0)
    if (fd < 0) {
        return false
    }

    try {
        val ulp = "tls".encodeToByteArray()
        val rc = ulp.usePinned { setsockopt(fd, IPPROTO_TCP, TCP_ULP, it.addressOf(0), ulp.size.convert()) }
        return rc == 0 || errno == ENOTCONN
    } finally {
        close(fd)
    }
}

// A file read whole; /proc files report no size, so it reads until the end.
@OptIn(ExperimentalForeignApi::class)
fun readFile(path: String): ByteArray? {
    val fd = open(path, O_RDONLY or O_CLOEXEC)
    if (fd < 0) {
        return null
    }

    try {
        var bytes = ByteArray(4096)
        var length = 0
        while (true) {
            if (length == bytes.size) {
                bytes = bytes.copyOf(bytes.size * 2)
            }

            val n = bytes.usePinned { read(fd, it.addressOf(length), (bytes.size - length).convert()) }
            if (n <= 0) {
                return bytes.copyOf(length)
            }
            length += n.toInt()
        }
    } finally {
        close(fd)
    }
}
