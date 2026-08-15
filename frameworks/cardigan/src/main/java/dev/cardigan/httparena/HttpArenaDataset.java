// SPDX-License-Identifier: MPL-2.0

package dev.cardigan.httparena;

import dev.cardigan.http.StreamingBody;
import dev.cardigan.serdes.Serdes;
import dev.cardigan.simdjson.ondemand.Value;

import java.io.IOException;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
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
            prefixes[index] = Arrays.copyOfRange(
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

    StreamingBody render(int requestedCount, long multiplier) {
        int count = Math.max(0, Math.min(requestedCount, itemPrefixes.length));
        int length = PREFIX.length + COUNT.length + digits(count) + 1;
        for (int index = 0; index < count; index++) {
            length += itemPrefixes[index].length + TOTAL.length + 1;
            length += digits(Math.multiplyExact(baseTotals[index], multiplier));
            if (index != 0) {
                length++;
            }
        }

        byte[] output = new byte[length];
        int offset = copy(PREFIX, output, 0);
        for (int index = 0; index < count; index++) {
            if (index != 0) {
                output[offset++] = ',';
            }
            offset = copy(itemPrefixes[index], output, offset);
            offset = copy(TOTAL, output, offset);
            offset = writeLong(
                output, offset,
                Math.multiplyExact(baseTotals[index], multiplier));
            output[offset++] = '}';
        }
        offset = copy(COUNT, output, offset);
        offset = writeLong(output, offset, count);
        output[offset++] = '}';
        if (offset != output.length) {
            throw new IllegalStateException("Incorrect JSON response length");
        }

        MemorySegment bytes = MemorySegment.ofArray(output);
        return StreamingBody.of(output.length, new StreamingBody.Reader() {
            private int position;

            @Override
            public int read(MemorySegment destination) {
                if (position == output.length) {
                    return -1;
                }
                int amount = Math.min(
                    output.length - position,
                    Math.toIntExact(destination.byteSize()));
                MemorySegment.copy(
                    bytes, position, destination, 0, amount);
                position += amount;
                return amount;
            }
        });
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

    private static int copy(byte[] source, byte[] target, int offset) {
        System.arraycopy(source, 0, target, offset, source.length);
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

    private static int writeLong(byte[] target, int offset, long value) {
        int length = digits(value);
        int end = offset + length;
        int cursor = end;
        boolean negative = value < 0;
        do {
            long remainder = value % 10;
            target[--cursor] = (byte) ('0' + Math.abs(remainder));
            value /= 10;
        } while (value != 0);
        if (negative) {
            target[offset] = '-';
        }
        return end;
    }

    private static boolean isWhitespace(byte value) {
        return value == ' ' || value == '\t'
            || value == '\r' || value == '\n';
    }
}
