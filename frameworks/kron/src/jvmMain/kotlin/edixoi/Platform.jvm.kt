package edixoi

import java.lang.foreign.Arena
import java.lang.foreign.FunctionDescriptor
import java.lang.foreign.Linker
import java.lang.foreign.MemoryLayout
import java.lang.foreign.ValueLayout.ADDRESS
import java.lang.foreign.ValueLayout.JAVA_INT
import java.lang.invoke.MethodHandles
import java.nio.ByteOrder
import java.nio.file.Files
import java.nio.file.Path

// What the JVM gave edixoi-kt for free, from the JDK; the kTLS probe through FFM, as the JDK has no setsockopt.

actual fun env(name: String): String? = System.getenv(name)

actual fun fileExists(path: String): Boolean = Files.exists(Path.of(path))

actual fun printErr(message: String) {
    System.err.println(message)
}

actual fun onlineProcessors(): Int = Runtime.getRuntime().availableProcessors()

actual fun readFile(path: String): ByteArray? =
    try {
        Files.readAllBytes(Path.of(path))
    } catch (_: Exception) {
        null
    }

actual fun kernelTlsAvailable(): Boolean {
    val linker = Linker.nativeLinker()
    val lookup = linker.defaultLookup()
    val capture = Linker.Option.captureCallState("errno")
    val stateLayout = Linker.Option.captureStateLayout()
    val socket = linker.downcallHandle(
        lookup.find("socket").orElseThrow(),
        FunctionDescriptor.of(JAVA_INT, JAVA_INT, JAVA_INT, JAVA_INT),
    )
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

private val LONGS = MethodHandles.byteArrayViewVarHandle(LongArray::class.java, ByteOrder.LITTLE_ENDIAN)
private val SHORTS = MethodHandles.byteArrayViewVarHandle(ShortArray::class.java, ByteOrder.LITTLE_ENDIAN)

actual fun ByteArray.putLong(index: Int, value: Long) {
    LONGS.set(this, index, value)
}

actual fun ByteArray.putShort(index: Int, value: Short) {
    SHORTS.set(this, index, value)
}

private const val AF_INET = 2
private const val SOCK_STREAM = 1
private const val SOCK_CLOEXEC = 0x80000
private const val IPPROTO_TCP = 6
private const val TCP_ULP = 31
private const val ENOTCONN = 107
