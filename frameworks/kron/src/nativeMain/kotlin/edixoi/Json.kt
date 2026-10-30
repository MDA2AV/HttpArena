package edixoi


/**
 * The dataset behind `/json/{count}?m=N`, parsed once at startup into UTF-8 so serializing a response is a walk
 * over it rather than a re-encode. Every field is written per request from this model - nothing about a response
 * is precomputed, since `total` depends on the multiplier the request carries.
 */
internal class Dataset private constructor(private val items: Array<Item>) {
    class Item(
        val id: Long,
        val name: Words,
        val category: Words,
        val price: Long,
        val quantity: Long,
        val active: Boolean,
        val tags: Array<Words>,
        val score: Long,
        val ratingCount: Long,
    )

    val count: Int get() = items.size

    /**
     * Serializes the first [count] items into [body], each item's `total` scaled by [multiplier], and returns the
     * bytes written.
     */
    fun write(body: Growable, count: Int, multiplier: Long): Int {
        val n = count.coerceIn(0, items.size)
        // One capacity check for the whole response: the bound is the items' widest form, so the writes below need
        // none of their own.
        val out = body.reserve(boundOfFirst[n])
        var at = put(out, 0, ITEMS_OPEN)
        for (i in 0 until n) {
            if (i > 0) at = put(out, at, COMMA)
            val item = items[i]
            at = put(out, at, ID)
            at = Ascii.writeLong(item.id, out, at)
            at = put(out, at, NAME)
            at = put(out, at, item.name)
            at = put(out, at, CATEGORY)
            at = put(out, at, item.category)
            at = put(out, at, PRICE)
            at = Ascii.writeLong(item.price, out, at)
            at = put(out, at, QUANTITY)
            at = Ascii.writeLong(item.quantity, out, at)
            at = put(out, at, if (item.active) ACTIVE_TRUE else ACTIVE_FALSE)
            for (t in item.tags.indices) {
                if (t > 0) at = put(out, at, COMMA)
                at = put(out, at, QUOTE)
                at = put(out, at, item.tags[t])
                at = put(out, at, QUOTE)
            }
            at = put(out, at, RATING)
            at = Ascii.writeLong(item.score, out, at)
            at = put(out, at, RATING_COUNT)
            at = Ascii.writeLong(item.ratingCount, out, at)
            at = put(out, at, TOTAL)
            at = Ascii.writeLong(item.price * item.quantity * multiplier, out, at)
            at = put(out, at, CLOSE_ITEM)
        }
        at = put(out, at, COUNT)
        at = Ascii.writeLong(n.toLong(), out, at)
        at = put(out, at, CLOSE_ITEM)
        body.commit(at)
        return at
    }

    // boundOfFirst[n]: no response of the first n items can be longer, whatever the multiplier.
    private val boundOfFirst = IntArray(items.size + 1).also { bound ->
        // + one word: a field is stored in whole words, up to seven bytes past the last.
        val fixed = ITEMS_OPEN.size + COUNT.size + Ascii.MAX_LONG_BYTES + CLOSE_ITEM.size + 8
        bound[0] = fixed
        for (i in items.indices) {
            val item = items[i]
            val literals = COMMA.size + ID.size + NAME.size + CATEGORY.size + PRICE.size + QUANTITY.size +
                ACTIVE_FALSE.size + RATING.size + RATING_COUNT.size + TOTAL.size + CLOSE_ITEM.size
            val tags = item.tags.sumOf { it.size + 2 * QUOTE.size + COMMA.size }
            bound[i + 1] = bound[i] + literals + item.name.size + item.category.size + tags + 6 * Ascii.MAX_LONG_BYTES
        }
    }

    // A field in whole words: up to seven bytes land past it, and the next write covers them.
    private fun put(out: ByteArray, at: Int, field: Words): Int {
        val words = field.words
        for (i in words.indices) out.setLongAt(at + 8 * i, words[i])
        return at + field.size
    }

    companion object {
        private val ITEMS_OPEN = Words("{\"items\":[".encodeToByteArray())
        private val COMMA = Words(",".encodeToByteArray())
        private val QUOTE = Words("\"".encodeToByteArray())
        private val ID = Words("{\"id\":".encodeToByteArray())
        private val NAME = Words(",\"name\":\"".encodeToByteArray())
        private val CATEGORY = Words("\",\"category\":\"".encodeToByteArray())
        private val PRICE = Words("\",\"price\":".encodeToByteArray())
        private val QUANTITY = Words(",\"quantity\":".encodeToByteArray())
        private val ACTIVE_TRUE = Words(",\"active\":true,\"tags\":[".encodeToByteArray())
        private val ACTIVE_FALSE = Words(",\"active\":false,\"tags\":[".encodeToByteArray())
        private val RATING = Words("],\"rating\":{\"score\":".encodeToByteArray())
        private val RATING_COUNT = Words(",\"count\":".encodeToByteArray())
        private val TOTAL = Words("},\"total\":".encodeToByteArray())
        private val CLOSE_ITEM = Words("}".encodeToByteArray())
        private val COUNT = Words("],\"count\":".encodeToByteArray())

        // After the literals: building it computes the size bound from them.
        val EMPTY = Dataset(emptyArray())

        fun load(path: String): Dataset = try {
            val text = readFile(path) ?: throw IllegalStateException("cannot read it")
            @Suppress("UNCHECKED_CAST")
            val root = JsonReader(text).read() as List<Map<String, Any?>>
            Dataset(Array(root.size) { i ->
                val element = root[i]
                val rating = element["rating"] as Map<*, *>
                val tags = element["tags"] as List<*>
                Item(
                    id = (element["id"] as Number).toLong(),
                    name = Words((element["name"] as String).encodeToByteArray()),
                    category = Words((element["category"] as String).encodeToByteArray()),
                    price = (element["price"] as Number).toLong(),
                    quantity = (element["quantity"] as Number).toLong(),
                    active = element["active"] as Boolean,
                    tags = Array(tags.size) { t -> Words((tags[t] as String).encodeToByteArray()) },
                    score = (rating["score"] as Number).toLong(),
                    ratingCount = (rating["count"] as Number).toLong(),
                )
            })
        } catch (e: Exception) {
            printErr("[kron] dataset load failed ($path): ${e.message}")
            EMPTY
        }
    }
}

/** Bytes, and the little-endian words that store them: a copy of a field is a store or three, not a call. */
internal class Words(bytes: ByteArray) {
    val size = bytes.size
    val words = LongArray((size + 7) / 8).also { w ->
        for (i in bytes.indices) w[i / 8] = w[i / 8] or ((bytes[i].toLong() and 0xFF) shl (8 * (i % 8)))
    }
}

/**
 * A grow-once scratch buffer: the JSON body has to exist before its Content-Length can be written, and an echo
 * of a chunked upload has to be decoded before its length is known. Both start empty and settle at a size within
 * a few requests, so a door that is never asked for either never allocates one.
 */
internal class Growable {
    var buffer = ByteArray(0)
        private set
    var length = 0
        private set

    fun reset() {
        length = 0
    }

    fun append(bytes: ByteArray, offset: Int = 0, count: Int = bytes.size - offset) {
        ensure(length + count)
        bytes.copyInto(buffer, length, offset, offset + count)
        length += count
    }

    fun append(value: Long) {
        ensure(length + Ascii.MAX_LONG_BYTES)
        length = Ascii.writeLong(value, buffer, length)
    }

    /** Empties the buffer and returns it with room for [capacity] bytes, for a writer that sets the length itself. */
    fun reserve(capacity: Int): ByteArray {
        length = 0
        ensure(capacity)
        return buffer
    }

    /** The length a [reserve] writer reached. */
    fun commit(written: Int) {
        length = written
    }

    private fun ensure(needed: Int) {
        if (buffer.size < needed) buffer = buffer.copyOf(maxOf(needed, buffer.size * 2))
    }
}

/** Decimal numbers in and out of ASCII bytes, the parsing with Utf8Parser's leniency: leading digits count. */
internal object Ascii {
    /** At most this many bytes for any Long, sign included. */
    const val MAX_LONG_BYTES = 20

    /** Writes [value] at [at] in [destination] and returns the position after it. */
    fun writeLong(value: Long, destination: ByteArray, at: Int): Int {
        // Every number a response carries fits an Int, whose division by a constant is the cheap one.
        if (value >= 0 && value <= Int.MAX_VALUE.toLong()) return writeInt(value.toInt(), destination, at)
        if (value < 0 && value > Int.MIN_VALUE.toLong()) {
            destination[at] = '-'.code.toByte()
            return writeInt(-value.toInt(), destination, at + 1)
        }
        return writeWide(value, destination, at)
    }

    // "00".."99" as little-endian shorts, so a pair is one 16-bit store.
    private val PAIRS16 = ShortArray(100) { (('0'.code + it / 10) or (('0'.code + it % 10) shl 8)).toShort() }

    // A non-negative Int. The widths the dataset's numbers come in are written straight; wider ones from the
    // end, a pair at a time.
    private fun writeInt(value: Int, destination: ByteArray, at: Int): Int {
        if (value < 10) {
            destination[at] = ('0'.code + value).toByte()
            return at + 1
        }
        if (value < 100) {
            destination.setShortAt(at, PAIRS16[value])
            return at + 2
        }
        if (value < 1_000) {
            val high = value / 100
            destination[at] = ('0'.code + high).toByte()
            destination.setShortAt(at + 1, PAIRS16[value - high * 100])
            return at + 3
        }
        if (value < 10_000) {
            val high = value / 100
            destination.setShortAt(at, PAIRS16[high])
            destination.setShortAt(at + 2, PAIRS16[value - high * 100])
            return at + 4
        }
        val end = at + digits(value)
        var pos = end
        var v = value
        while (v >= 100) {
            val q = v / 100
            pos -= 2
            destination.setShortAt(pos, PAIRS16[v - q * 100])
            v = q
        }
        if (v >= 10) destination.setShortAt(pos - 2, PAIRS16[v]) else destination[pos - 1] = ('0'.code + v).toByte()
        return end
    }

    private fun digits(v: Int): Int = when {
        v < 10 -> 1
        v < 100 -> 2
        v < 1_000 -> 3
        v < 10_000 -> 4
        v < 100_000 -> 5
        v < 1_000_000 -> 6
        v < 10_000_000 -> 7
        v < 100_000_000 -> 8
        v < 1_000_000_000 -> 9
        else -> 10
    }

    // The rest of the Long range, by negative accumulation so Long.MIN_VALUE needs no special case.
    private fun writeWide(value: Long, destination: ByteArray, at: Int): Int {
        var pos = at
        var v = if (value < 0) value else -value
        if (value < 0) destination[pos++] = '-'.code.toByte()
        val start = pos
        while (v != 0L) {
            destination[pos++] = ('0'.code - (v % 10).toInt()).toByte()
            v /= 10
        }
        destination.reverse(start, pos)
        return pos
    }

    /**
     * The number at the start of [bytes] in [from, to): an optional sign, then decimal digits up to the first
     * byte that is not one. Null when there are no digits or the value overflows a Long.
     */
    fun parseLong(bytes: ByteArray, from: Int, to: Int): Long? {
        var i = from
        var negative = false
        if (i < to && (bytes[i] == '-'.code.toByte() || bytes[i] == '+'.code.toByte())) {
            negative = bytes[i] == '-'.code.toByte()
            i++
        }
        val digitsStart = i
        var value = 0L
        while (i < to) {
            val d = bytes[i] - '0'.code.toByte()
            if (d !in 0..9) break
            if (value > (Long.MAX_VALUE - d) / 10) return null
            value = value * 10 + d
            i++
        }
        if (i == digitsStart) return null
        return if (negative) -value else value
    }

    /** As [parseLong], into an Int. */
    fun parseInt(bytes: ByteArray, from: Int, to: Int): Int? {
        val value = parseLong(bytes, from, to) ?: return null
        return if (value in Int.MIN_VALUE..Int.MAX_VALUE) value.toInt() else null
    }
}

/** Just enough JSON to read the dataset at startup: objects, arrays, strings, numbers, booleans and null. */
private class JsonReader(private val text: ByteArray) {
    private var at = 0

    fun read(): Any? {
        val value = value()
        skipSpace()
        require(at == text.size) { "trailing data at $at" }
        return value
    }

    private fun value(): Any? {
        skipSpace()
        require(at < text.size) { "unexpected end" }
        return when (text[at].toInt().toChar()) {
            '{' -> obj()
            '[' -> array()
            '"' -> string()
            't' -> literal("true", true)
            'f' -> literal("false", false)
            'n' -> literal("null", null)
            else -> number()
        }
    }

    private fun obj(): Map<String, Any?> {
        at++
        val map = LinkedHashMap<String, Any?>()
        skipSpace()
        if (text[at] == '}'.code.toByte()) {
            at++
            return map
        }
        while (true) {
            skipSpace()
            val key = string()
            skipSpace()
            expect(':')
            map[key] = value()
            skipSpace()
            if (text[at] == ','.code.toByte()) {
                at++
                continue
            }
            expect('}')
            return map
        }
    }

    private fun array(): List<Any?> {
        at++
        val list = ArrayList<Any?>()
        skipSpace()
        if (text[at] == ']'.code.toByte()) {
            at++
            return list
        }
        while (true) {
            list.add(value())
            skipSpace()
            if (text[at] == ','.code.toByte()) {
                at++
                continue
            }
            expect(']')
            return list
        }
    }

    private fun string(): String {
        expect('"')
        val out = Bytes()
        while (true) {
            val b = text[at++]
            when (b) {
                '"'.code.toByte() -> return out.decode()
                '\\'.code.toByte() -> when (val e = text[at++].toInt().toChar()) {
                    '"', '\\', '/' -> out.write(e.code)
                    'b' -> out.write(8)
                    'f' -> out.write(12)
                    'n' -> out.write(10)
                    'r' -> out.write(13)
                    't' -> out.write(9)
                    'u' -> {
                        val code = text.decodeToString(at, at + 4).toInt(16)
                        at += 4
                        out.write(code.toChar().toString().encodeToByteArray())
                    }
                    else -> throw IllegalArgumentException("bad escape \\$e at $at")
                }
                else -> out.write(b.toInt())
            }
        }
    }

    private fun number(): Number {
        val start = at
        while (at < text.size && text[at].toInt().toChar() in "+-0123456789.eE") at++
        val literal = text.decodeToString(start, at)
        return literal.toLongOrNull() ?: literal.toDouble()
    }

    private fun literal(word: String, value: Any?): Any? {
        require(text.decodeToString(at, at + word.length) == word) { "bad literal at $at" }
        at += word.length
        return value
    }

    private fun expect(c: Char) {
        require(at < text.size && text[at] == c.code.toByte()) { "expected '$c' at $at" }
        at++
    }

    private fun skipSpace() {
        while (at < text.size && text[at].toInt().toChar().isWhitespace()) at++
    }
}
