package edixoi

import kotlinx.cinterop.addressOf
import kotlinx.cinterop.convert
import kotlinx.cinterop.toKString
import kotlinx.cinterop.usePinned
import platform.posix.AF_INET
import platform.posix.EINTR
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
import platform.posix.fputs
import platform.posix.getenv
import platform.posix.open
import platform.posix.read
import platform.posix.setsockopt
import platform.posix.socket
import platform.posix.stderr
import platform.posix.sysconf

// What the JVM gave edixoi-kt for free, on Kotlin/Native.

fun env(name: String): String? = getenv(name)?.toKString()

fun fileExists(path: String): Boolean = access(path, F_OK) == 0

fun printErr(message: String) {
    fputs(message + "\n", stderr)
}

/**
 * The CPUs this process may run on, as the JVM's availableProcessors counts them: the affinity list, which a
 * container's cpuset narrows, and the online count when that cannot be read.
 */
fun availableProcessors(): Int {
    val status = readFile("/proc/self/status")?.decodeToString()
    val line = status?.lineSequence()?.firstOrNull { it.startsWith("Cpus_allowed_list:") }
    if (line == null) {
        return sysconf(_SC_NPROCESSORS_ONLN).toInt()
    }

    var count = 0
    for (range in line.substringAfter(':').trim().split(',')) {
        val bounds = range.split('-')
        val first = bounds[0].toIntOrNull() ?: continue
        val last = if (bounds.size > 1) bounds[1].toIntOrNull() ?: first else first
        count += last - first + 1
    }

    return if (count > 0) count else sysconf(_SC_NPROCESSORS_ONLN).toInt()
}

// From linux/tcp.h: the toolchain's glibc 2.19 headers predate it.
private const val TCP_ULP = 31

/**
 * Whether the kernel can take TLS records. Setting the tls ULP on a socket that is not connected asks the kernel
 * itself: ENOTCONN once the module is in, ENOENT when it is not. The ULP list under /proc/sys/net cannot answer it,
 * as it exists only in the host's network namespace and a container on its own network does not see it.
 */
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

/** The whole file at [path], or null when it cannot be opened or read. */
fun readFile(path: String): ByteArray? {
    val fd = open(path, O_RDONLY or O_CLOEXEC)
    if (fd < 0) {
        return null
    }

    try {
        var bytes = ByteArray(64 * 1024)
        var length = 0
        while (true) {
            if (length == bytes.size) {
                bytes = bytes.copyOf(bytes.size * 2)
            }

            val buffer = bytes
            val n = buffer.usePinned { read(fd, it.addressOf(length), (buffer.size - length).convert()) }
            if (n < 0) {
                if (errno == EINTR) {
                    continue
                }

                return null
            }

            if (n == 0L) {
                return bytes.copyOf(length)
            }

            length += n.toInt()
        }
    } finally {
        close(fd)
    }
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
