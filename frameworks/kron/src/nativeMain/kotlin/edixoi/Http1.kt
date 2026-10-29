package edixoi

/**
 * Where a response goes. Plaintext writes land in the connection's write slab; a TLS connection encrypts into the
 * same slab through its session. One indirection here rather than a second copy of every endpoint, and it is what
 * lets one router answer on both doors.
 */
internal interface Sink {
    fun write(bytes: ByteArray, offset: Int, length: Int)
}

/**
 * The HTTP/1.1 half of the entry, edixoi's Http1.cs in Kotlin: parse whole requests out of a byte array, answer
 * them, and say how much was consumed. Everything here is synchronous - the reads, the send and the one wait are
 * the caller's, so this never touches the ring.
 *
 *     GET|POST /baseline11?a=&b=   text/plain, a + b (+ body)
 *     GET      /json/{count}?m=N   application/json, total = price * quantity * N
 *     POST     /echo               the request body, byte for byte
 *     GET      /delay/{ms}         text/plain, {ms}, after waiting that long
 *
 * The delay is the one thing this cannot finish on its own: it hands the caller the milliseconds and the caller,
 * which can suspend, does the waiting and writes the answer.
 *
 * One per reactor. A reactor runs one thread and [serve] never suspends, so no connection can be inside it while
 * another is - which is what makes the buffers below shareable, and the results fields too.
 */
internal class Http1(private val dataset: Dataset) {
    // One pair per reactor. Both exist because a Content-Length has to be written before the bytes it counts: an
    // upload has to be decoded before it can be echoed, and a JSON body built before it can be sent. Separate, so
    // echoing a chunked upload cannot be clobbered by the response assembled over it.
    private val upload = Growable()
    private val response = Growable()
    private val head = ByteArray(160)

    // What the last serve left behind, read by the caller straight after it: Kotlin has no out parameters.
    /** The connection asked to be closed, or a request was refused. */
    var close = false
        private set

    /** A request asked to be delayed by this many milliseconds; [NO_DELAY] when none did. */
    var delayMs = NO_DELAY
        private set

    // The request being served: its path and query, and its body, either in the input or decoded into upload.
    private var pathStart = 0
    private var pathEnd = 0
    private var queryStart = 0
    private var queryEnd = 0
    private var contentLength = 0
    private var chunked = false
    private var wantsClose = false
    private var wireLength = 0

    /**
     * Answers every complete request in [input] up to [length] and returns the bytes consumed. Stops early when a
     * request asks to be delayed, leaving the wait in [delayMs] for the caller to serve; what is left is a partial
     * request. [delayMs] is [NO_DELAY] for "nothing to wait on", not 0: `/delay/0` is a request the profile makes.
     */
    fun serve(sink: Sink, input: ByteArray, length: Int, closing: Boolean): Int {
        close = closing
        delayMs = NO_DELAY
        var consumed = 0
        while (!close && delayMs == NO_DELAY) {
            val taken = serveOne(sink, input, consumed, length)
            if (taken == 0) break   // incomplete: wait for more bytes
            consumed += taken
        }
        return consumed
    }

    // Bytes consumed by one request, or 0 when it has not all arrived yet.
    private fun serveOne(sink: Sink, input: ByteArray, start: Int, end: Int): Int {
        val headEnd = indexOfHeadEnd(input, start, end)
        if (headEnd < 0) {
            if (end - start > MAX_HEAD_BYTES) fail(sink)
            return 0
        }
        val bodyStart = headEnd + 4

        val lineEnd = indexOfCrlf(input, start, headEnd)
        if (!readTarget(input, start, if (lineEnd < 0) headEnd else lineEnd)) {
            fail(sink)
            return end - start
        }

        readHeaders(input, if (lineEnd < 0) headEnd else lineEnd + 2, headEnd)

        // The body, decoded. Chunked uploads land in the scratch so /echo can send them back and /baseline11 can
        // read their digits; a Content-Length body is already contiguous.
        val body: ByteArray
        val bodyOffset: Int
        val bodyLength: Int
        if (chunked) {
            val decoded = readChunked(input, bodyStart, end)
            if (decoded == INCOMPLETE) return 0
            if (decoded == MALFORMED) {
                fail(sink)
                return end - start
            }
            body = upload.buffer
            bodyOffset = 0
            bodyLength = decoded
        } else {
            // Unsigned and bounded before it is used as a length: it came off the wire.
            if (contentLength < 0 || contentLength > MAX_BODY_BYTES) {
                fail(sink)
                return end - start
            }
            if (end - bodyStart < contentLength) return 0
            body = input
            bodyOffset = bodyStart
            bodyLength = contentLength
            wireLength = contentLength
        }

        // Only now, with the whole request in hand: applying it while parsing the head would half-close the socket
        // on a request whose body is still on its way.
        close = wantsClose

        route(sink, input, body, bodyOffset, bodyLength)
        return bodyStart - start + wireLength
    }

    private fun route(sink: Sink, input: ByteArray, body: ByteArray, bodyOffset: Int, bodyLength: Int) {
        if (pathIs(input, BASELINE)) {
            writeText(sink, sum(input, queryStart, queryEnd) + digits(body, bodyOffset, bodyLength), close)
            return
        }

        if (pathIs(input, ECHO)) {
            writeBody(sink, OCTET_STREAM, body, bodyOffset, bodyLength, close)
            return
        }

        // /json/{count}?m=N and /delay/{ms} both carry their argument in the path.
        if (pathStartsWith(input, JSON_PREFIX)) {
            val count = Ascii.parseInt(input, pathStart + JSON_PREFIX.size, pathEnd) ?: 0
            val multiplier = value(input, queryStart, queryEnd, M, fallback = 1)
            val written = dataset.write(response, count, multiplier)
            writeBody(sink, APPLICATION_JSON, response.buffer, 0, written, close)
            return
        }

        if (pathStartsWith(input, DELAY_PREFIX)) {
            val ms = Ascii.parseInt(input, pathStart + DELAY_PREFIX.size, pathEnd)
            if (ms != null && ms >= 0) {
                // Handed back rather than served: the wait belongs on the ring, and only the caller can suspend.
                delayMs = ms
                return
            }
        }

        sink.write(NOT_FOUND, 0, NOT_FOUND.size)
    }

    // ── request line ─────────────────────────────────────────────────────────────────────────────────────

    // Splits "GET /json/5?m=7 HTTP/1.1" into its path and its query string.
    private fun readTarget(input: ByteArray, from: Int, to: Int): Boolean {
        val afterMethod = indexOf(input, from, to, SPACE)
        if (afterMethod < 0) return false
        val targetStart = afterMethod + 1
        val targetEnd = indexOf(input, targetStart, to, SPACE)
        if (targetEnd < 0) return false

        val mark = indexOf(input, targetStart, targetEnd, QUESTION)
        pathStart = targetStart
        if (mark < 0) {
            pathEnd = targetEnd
            queryStart = targetEnd
            queryEnd = targetEnd
        } else {
            pathEnd = mark
            queryStart = mark + 1
            queryEnd = targetEnd
        }
        return true
    }

    private fun pathIs(input: ByteArray, path: ByteArray): Boolean =
        pathEnd - pathStart == path.size && regionEquals(input, pathStart, path)

    // "/json/5" against "/json/" - with something after the prefix.
    private fun pathStartsWith(input: ByteArray, prefix: ByteArray): Boolean =
        pathEnd - pathStart > prefix.size && regionEquals(input, pathStart, prefix)

    // Every value in the query string, added up - which is what /baseline11 answers.
    private fun sum(input: ByteArray, from: Int, to: Int): Long {
        var total = 0L
        var at = from
        while (at < to) {
            val amp = indexOf(input, at, to, AMP).let { if (it < 0) to else it }
            val equals = indexOf(input, at, amp, EQUALS)
            if (equals >= 0) Ascii.parseLong(input, equals + 1, amp)?.let { total += it }
            at = amp + 1
        }
        return total
    }

    // One named query value, for the /json multiplier.
    private fun value(input: ByteArray, from: Int, to: Int, name: ByteArray, fallback: Long): Long {
        var at = from
        while (at < to) {
            val amp = indexOf(input, at, to, AMP).let { if (it < 0) to else it }
            val equals = indexOf(input, at, amp, EQUALS)
            if (equals >= 0 && equals - at == name.size && regionEquals(input, at, name)) {
                Ascii.parseLong(input, equals + 1, amp)?.let { return it }
            }
            at = amp + 1
        }
        return fallback
    }

    // ── headers and body ─────────────────────────────────────────────────────────────────────────────────

    // The three header fields these endpoints read. Field names are case-insensitive (RFC 9110 5.1) and the load
    // generator sends both spellings, so every comparison here ignores case.
    private fun readHeaders(input: ByteArray, from: Int, to: Int) {
        contentLength = 0
        chunked = false
        wantsClose = false

        var at = from
        while (at < to) {
            val end = indexOfCrlf(input, at, to).let { if (it < 0) to else it }
            val colon = indexOf(input, at, end, COLON)
            if (colon >= 0) {
                var valueStart = colon + 1
                var valueEnd = end
                while (valueStart < valueEnd && input[valueStart] == SPACE) valueStart++
                while (valueEnd > valueStart && input[valueEnd - 1] == SPACE) valueEnd--

                if (equalsIgnoreCase(input, at, colon, CONTENT_LENGTH)) {
                    contentLength = Ascii.parseInt(input, valueStart, valueEnd) ?: 0
                } else if (equalsIgnoreCase(input, at, colon, TRANSFER_ENCODING)) {
                    chunked = equalsIgnoreCase(input, valueStart, valueEnd, CHUNKED)
                } else if (equalsIgnoreCase(input, at, colon, CONNECTION)) {
                    wantsClose = equalsIgnoreCase(input, valueStart, valueEnd, CLOSE)
                }
            }
            at = end + 2
        }
    }

    // Decodes a chunked body into upload and returns its decoded length, or INCOMPLETE / MALFORMED - telling those
    // apart is what stops a chunk size of ffffffff being waited on forever. wireLength is what the framing occupied,
    // which is what the caller skips to reach the next request: one walk answers both, so they cannot disagree.
    private fun readChunked(input: ByteArray, from: Int, to: Int): Int {
        upload.reset()
        wireLength = 0
        var at = from
        while (true) {
            val end = indexOfCrlf(input, at, to)
            if (end < 0) return INCOMPLETE

            // The size line may carry a chunk extension ("2;name=value"), which the hex read stops at and this
            // ignores, as every server here does.
            val size = parseHex(input, at, end)
            if (size < 0 || size > MAX_BODY_BYTES) return MALFORMED
            at = end + 2

            if (size == 0) {
                // The trailer section, empty in everything this serves, ends with its own CRLF.
                val trailer = indexOfCrlf(input, at, to)
                if (trailer < 0) return INCOMPLETE
                wireLength = trailer + 2 - from
                return upload.length
            }

            if (to - at < size + 2) return INCOMPLETE
            upload.append(input, at, size)
            at += size + 2
        }
    }

    // A body that is a decimal number, as /baseline11's is. Anything that is not a digit is not part of that number.
    private fun digits(body: ByteArray, offset: Int, length: Int): Long {
        var value = 0L
        for (i in offset until offset + length) {
            val d = body[i] - '0'.code.toByte()
            if (d in 0..9) value = value * 10 + d
        }
        return value
    }

    // ── responses ────────────────────────────────────────────────────────────────────────────────────────

    /** The delay profile's answer, written by the caller once its wait is over. */
    fun writeDelayed(sink: Sink, ms: Int, close: Boolean) = writeText(sink, ms.toLong(), close)

    private fun writeText(sink: Sink, value: Long, close: Boolean) {
        val bodyStart = head.size - 20
        val bodyEnd = Ascii.writeLong(value, head, bodyStart)
        // The digits sit at the end of the head scratch; the head itself is written in front of them.
        writeHead(sink, TEXT_PLAIN, bodyEnd - bodyStart, close)
        sink.write(head, bodyStart, bodyEnd - bodyStart)
    }

    private fun writeBody(sink: Sink, contentType: ByteArray, body: ByteArray, offset: Int, length: Int, close: Boolean) {
        writeHead(sink, contentType, length, close)
        sink.write(body, offset, length)
    }

    private fun writeHead(sink: Sink, contentType: ByteArray, contentLength: Int, close: Boolean) {
        var at = 0
        at = put(STATUS_OK, at)
        at = put(contentType, at)
        at = put(CONTENT_LENGTH_HEADER, at)
        at = Ascii.writeLong(contentLength.toLong(), head, at)
        at = put(CRLF, at)
        if (close) at = put(CONNECTION_CLOSE, at)
        at = put(CRLF, at)
        sink.write(head, 0, at)
    }

    private fun put(bytes: ByteArray, at: Int): Int {
        bytes.copyInto(head, at)
        return at + bytes.size
    }

    private fun fail(sink: Sink) {
        sink.write(BAD_REQUEST, 0, BAD_REQUEST.size)
        close = true
    }

    companion object {
        /** Cap on one request's head, so a peer that never sends CRLFCRLF cannot grow the carry. */
        const val MAX_HEAD_BYTES = 16 * 1024

        /** The same for a declared body length, which is a number the peer chooses. */
        private const val MAX_BODY_BYTES = 1 shl 20

        private const val INCOMPLETE = -1   // the rest is still on its way
        private const val MALFORMED = -2    // it is never going to arrive

        /** No request asked to be delayed. Distinct from a delay of zero, which is one. */
        const val NO_DELAY = -1

        private val BAD_REQUEST =
            "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encodeToByteArray()
        private val NOT_FOUND = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n".encodeToByteArray()
        private val STATUS_OK = "HTTP/1.1 200 OK\r\nContent-Type: ".encodeToByteArray()
        private val CONTENT_LENGTH_HEADER = "\r\nContent-Length: ".encodeToByteArray()
        private val CONNECTION_CLOSE = "Connection: close\r\n".encodeToByteArray()
        private val CRLF = "\r\n".encodeToByteArray()
        private val TEXT_PLAIN = "text/plain".encodeToByteArray()
        private val OCTET_STREAM = "application/octet-stream".encodeToByteArray()
        private val APPLICATION_JSON = "application/json".encodeToByteArray()

        private val BASELINE = "/baseline11".encodeToByteArray()
        private val ECHO = "/echo".encodeToByteArray()
        private val JSON_PREFIX = "/json/".encodeToByteArray()
        private val DELAY_PREFIX = "/delay/".encodeToByteArray()
        private val M = "m".encodeToByteArray()

        private val CONTENT_LENGTH = "content-length".encodeToByteArray()
        private val TRANSFER_ENCODING = "transfer-encoding".encodeToByteArray()
        private val CONNECTION = "connection".encodeToByteArray()
        private val CHUNKED = "chunked".encodeToByteArray()
        private val CLOSE = "close".encodeToByteArray()

        private const val CR = '\r'.code.toByte()
        private const val LF = '\n'.code.toByte()
        private const val SPACE = ' '.code.toByte()
        private const val QUESTION = '?'.code.toByte()
        private const val AMP = '&'.code.toByte()
        private const val EQUALS = '='.code.toByte()
        private const val COLON = ':'.code.toByte()

        private fun indexOf(input: ByteArray, from: Int, to: Int, b: Byte): Int {
            for (i in from until to) if (input[i] == b) return i
            return -1
        }

        private fun indexOfCrlf(input: ByteArray, from: Int, to: Int): Int {
            for (i in from until to - 1) if (input[i] == CR && input[i + 1] == LF) return i
            return -1
        }

        private fun indexOfHeadEnd(input: ByteArray, from: Int, to: Int): Int {
            var i = from
            while (i <= to - 4) {
                // The fourth byte first: a request is mostly not LF, so most positions are rejected on one compare.
                if (input[i + 3] != LF) {
                    i++
                    continue
                }
                if (input[i] == CR && input[i + 1] == LF && input[i + 2] == CR) return i
                i++
            }
            return -1
        }

        private fun regionEquals(input: ByteArray, at: Int, expected: ByteArray): Boolean {
            for (i in expected.indices) if (input[at + i] != expected[i]) return false
            return true
        }

        // ASCII case-insensitive, against a lower-case expectation.
        private fun equalsIgnoreCase(input: ByteArray, from: Int, to: Int, lower: ByteArray): Boolean {
            if (to - from != lower.size) return false
            for (i in lower.indices) {
                var c = input[from + i].toInt()
                if (c in 'A'.code..'Z'.code) c += 32
                if (c != lower[i].toInt()) return false
            }
            return true
        }

        // Hex digits up to the first byte that is not one; -1 when there are none or more than an Int's eight.
        private fun parseHex(input: ByteArray, from: Int, to: Int): Int {
            var value = 0L
            var i = from
            while (i < to) {
                val c = input[i].toInt()
                val d = when (c) {
                    in '0'.code..'9'.code -> c - '0'.code
                    in 'a'.code..'f'.code -> c - 'a'.code + 10
                    in 'A'.code..'F'.code -> c - 'A'.code + 10
                    else -> break
                }
                if (i - from == 8) return -1
                value = value * 16 + d
                i++
            }
            return if (i == from || value > Int.MAX_VALUE) -1 else value.toInt()
        }
    }
}
