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

// What the JVM gave edixoi-kt for free, from posix.

actual fun env(name: String): String? = getenv(name)?.toKString()

actual fun fileExists(path: String): Boolean = access(path, F_OK) == 0

actual fun printErr(message: String) {
    fputs(message + "\n", stderr)
}

actual fun onlineProcessors(): Int = sysconf(_SC_NPROCESSORS_ONLN).toInt()


// From linux/tcp.h: the toolchain's glibc 2.19 headers predate it.
private const val TCP_ULP = 31

actual fun kernelTlsAvailable(): Boolean {
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

actual fun readFile(path: String): ByteArray? {
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

// Inline, so the JSON writer's stores stay single instructions natively.
@Suppress("NOTHING_TO_INLINE")
actual inline fun ByteArray.putLong(index: Int, value: Long) = setLongAt(index, value)

@Suppress("NOTHING_TO_INLINE")
actual inline fun ByteArray.putShort(index: Int, value: Short) = setShortAt(index, value)
