package httparena

import java.lang.foreign.Arena
import java.lang.foreign.FunctionDescriptor
import java.lang.foreign.Linker
import java.lang.foreign.MemoryLayout
import java.lang.foreign.ValueLayout.ADDRESS
import java.lang.foreign.ValueLayout.JAVA_INT
import java.nio.file.Files
import java.nio.file.Path

actual fun env(name: String): String? = System.getenv(name)

actual fun onlineProcessors(): Int = Runtime.getRuntime().availableProcessors()

actual fun fileExists(path: String): Boolean = Files.exists(Path.of(path))

actual fun readFile(path: String): ByteArray? =
    try {
        Files.readAllBytes(Path.of(path))
    } catch (_: Exception) {
        null
    }

// The native probe's calls, through FFM: socket, setsockopt with errno, close.
actual fun kernelTlsAvailable(): Boolean {
    val linker = Linker.nativeLinker()
    val lookup = linker.defaultLookup()
    val capture = Linker.Option.captureCallState("errno")
    val stateLayout = Linker.Option.captureStateLayout()
    val socket = linker.downcallHandle(lookup.find("socket").orElseThrow(), FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT))
    val setsockopt = linker.downcallHandle(
        lookup.find("setsockopt").orElseThrow(),
        FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT, ADDRESS, JAVA_INT),
        capture,
    )
    val close = linker.downcallHandle(lookup.find("close").orElseThrow(), FunctionDescriptor.of(JAVA_INT, JAVA_INT))

    val fd = socket.invokeExact(AF_INET, SOCK_STREAM or SOCK_CLOEXEC, 0) as Int
    if (fd < 0) {
        return false
    }

    try {
        Arena.ofConfined().use { arena ->
            val state = arena.allocate(stateLayout)
            val ulp = arena.allocateFrom("tls")
            val rc = setsockopt.invokeExact(state, fd, IPPROTO_TCP, TCP_ULP, ulp, 3) as Int
            val errno = state.get(JAVA_INT, stateLayout.byteOffset(MemoryLayout.PathElement.groupElement("errno")))
            return rc == 0 || errno == ENOTCONN
        }
    } finally {
        close.invokeExact(fd) as Int
    }
}

private const val AF_INET = 2
private const val SOCK_STREAM = 1
private const val SOCK_CLOEXEC = 0x80000
private const val IPPROTO_TCP = 6
private const val TCP_ULP = 31
private const val ENOTCONN = 107
