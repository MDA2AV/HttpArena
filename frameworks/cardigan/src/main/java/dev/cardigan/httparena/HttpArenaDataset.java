// SPDX-License-Identifier: MPL-2.0

package dev.cardigan.httparena;

import dev.cardigan.ffi.RawSegment;
import dev.cardigan.http.EncodedBody;
import dev.cardigan.serdes.Serdes;
import dev.cardigan.simdjson.ondemand.Value;

import java.io.IOException;
import java.lang.foreign.MemorySegment;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Immutable startup representation of HttpArena's mounted JSON dataset. */
final class HttpArenaDataset {
    private static final byte[] PREFIX =
        "{\"items\":[".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] TOTAL =
        ",\"total\":".getBytes(StandardCharsets.US_ASCII);
    private static final byte[] COUNT =
        "],\"count\":".getBytes(StandardCharsets.US_ASCII);

    private final byte[][] itemPrefixes;
    private final long[] baseTotals;

    private HttpArenaDataset(byte[][] itemPrefixes, long[] baseTotals) {
        this.itemPrefixes = itemPrefixes;
        this.baseTotals = baseTotals;
    }

    static HttpArenaDataset load(Path path) throws IOException {
        byte[] source = Files.readAllBytes(path);
        List<int[]> ranges = itemRanges(source);
        byte[][] prefixes = new byte[ranges.size()][];
        long[] totals = new long[ranges.size()];
        for (int index = 0; index < ranges.size(); index++) {
            int[] range = ranges.get(index);
            int close = range[1] - 1;
            while (close > range[0] && isWhitespace(source[close])) {
                close--;
            }
            if (source[close] != '}') {
                throw new IllegalArgumentException(
                    "Dataset item is not a JSON object");
            }
            prefixes[index] = compactJson(
                source, range[0], close);
            Value item = Serdes.parseOnDemand(
                MemorySegment.ofArray(source),
                range[0], range[1] - range[0]);
            totals[index] = Math.multiplyExact(
                item.get("price").getLong(),
                item.get("quantity").getLong());
        }
        if (prefixes.length < 50) {
            throw new IllegalArgumentException(
                "HttpArena dataset must contain at least 50 items");
        }
        return new HttpArenaDataset(prefixes, totals);
    }

    EncodedBody render(int requestedCount, long multiplier) {
        int count = Math.max(0, Math.min(requestedCount, itemPrefixes.length));
        int length = PREFIX.length + COUNT.length + digits(count) + 1;
        for (int index = 0; index < count; index++) {
            length += itemPrefixes[index].length + TOTAL.length + 1;
            length += digits(Math.multiplyExact(baseTotals[index], multiplier));
            if (index != 0) {
                length++;
            }
        }

        int encodedLength = length;
        return EncodedBody.of(
            encodedLength,
            output -> renderInto(
                output.address(), count, multiplier, encodedLength));
    }

    private int renderInto(
            long outputAddress,
            int count,
            long multiplier,
            int length) {
        int offset = copy(PREFIX, outputAddress, 0);
        for (int index = 0; index < count; index++) {
            if (index != 0) {
                putByte(outputAddress, offset++, (byte) ',');
            }
            offset = copy(itemPrefixes[index], outputAddress, offset);
            offset = copy(TOTAL, outputAddress, offset);
            offset = writeLong(
                outputAddress, offset,
                Math.multiplyExact(baseTotals[index], multiplier));
            putByte(outputAddress, offset++, (byte) '}');
        }
        offset = copy(COUNT, outputAddress, offset);
        offset = writeLong(outputAddress, offset, count);
        putByte(outputAddress, offset++, (byte) '}');
        if (offset != length) {
            throw new IllegalStateException("Incorrect JSON response length");
        }
        return offset;
    }

    int size() {
        return itemPrefixes.length;
    }

    private static List<int[]> itemRanges(byte[] source) {
        List<int[]> ranges = new ArrayList<>();
        boolean string = false;
        boolean escaped = false;
        int arrayDepth = 0;
        int objectDepth = 0;
        int start = -1;
        for (int index = 0; index < source.length; index++) {
            byte current = source[index];
            if (string) {
                if (escaped) {
                    escaped = false;
                } else if (current == '\\') {
                    escaped = true;
                } else if (current == '"') {
                    string = false;
                }
                continue;
            }
            if (current == '"') {
                string = true;
            } else if (current == '[') {
                arrayDepth++;
            } else if (current == ']') {
                arrayDepth--;
            } else if (current == '{') {
                if (arrayDepth == 1 && objectDepth == 0) {
                    start = index;
                }
                objectDepth++;
            } else if (current == '}') {
                objectDepth--;
                if (arrayDepth == 1 && objectDepth == 0 && start >= 0) {
                    ranges.add(new int[] {start, index + 1});
                    start = -1;
                }
            }
            if (arrayDepth < 0 || objectDepth < 0) {
                throw new IllegalArgumentException("Malformed JSON dataset");
            }
        }
        if (string || arrayDepth != 0 || objectDepth != 0 || ranges.isEmpty()) {
            throw new IllegalArgumentException("Malformed JSON dataset");
        }
        return ranges;
    }

    private static byte[] compactJson(byte[] source, int start, int end) {
        byte[] compacted = new byte[end - start];
        int output = 0;
        boolean string = false;
        boolean escaped = false;
        for (int index = start; index < end; index++) {
            byte current = source[index];
            if (string) {
                compacted[output++] = current;
                if (escaped) {
                    escaped = false;
                } else if (current == '\\') {
                    escaped = true;
                } else if (current == '"') {
                    string = false;
                }
            } else if (current == '"') {
                string = true;
                compacted[output++] = current;
            } else if (!isWhitespace(current)) {
                compacted[output++] = current;
            }
        }
        if (string) {
            throw new IllegalArgumentException("Malformed JSON dataset");
        }
        return output == compacted.length
            ? compacted : Arrays.copyOf(compacted, output);
    }

    private static int copy(byte[] source, long target, int offset) {
        RawSegment.copy(source, 0, target + offset, source.length);
        return offset + source.length;
    }

    private static int digits(long value) {
        int result = value < 0 ? 2 : 1;
        while (value <= -10 || value >= 10) {
            value /= 10;
            result++;
        }
        return result;
    }

    private static int writeLong(long target, int offset, long value) {
        int length = digits(value);
        int end = offset + length;
        int cursor = end;
        boolean negative = value < 0;
        do {
            long remainder = value % 10;
            putByte(
                target,
                --cursor,
                (byte) ('0' + Math.abs(remainder)));
            value /= 10;
        } while (value != 0);
        if (negative) {
            putByte(target, offset, (byte) '-');
        }
        return end;
    }

    private static void putByte(long target, int offset, byte value) {
        RawSegment.BYTE.set(
            RawSegment.ADDRESS_SPACE, target + offset, value);
    }

    private static boolean isWhitespace(byte value) {
        return value == ' ' || value == '\t'
            || value == '\r' || value == '\n';
    }
}
