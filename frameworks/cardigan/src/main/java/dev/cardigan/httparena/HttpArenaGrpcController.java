// SPDX-License-Identifier: MPL-2.0

package dev.cardigan.httparena;

import dev.cardigan.http.DecodedBody;
import dev.cardigan.http.LongBodyDecoder;
import dev.cardigan.http.Post;
import dev.cardigan.http.Response;
import dev.cardigan.http.ResponseHeaders;
import dev.cardigan.http.StreamingBody;

import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.nio.ByteOrder;

/** Implements the two gRPC methods exercised by HttpArena. */
public final class HttpArenaGrpcController {
    private static final String CONTENT_TYPE = "application/grpc";
    private static final int MAX_STREAM_REPLIES = 1_000_000;
    private static final long INVALID_REQUEST = 0xffff_ffff_0000_0000L;
    private static final ValueLayout.OfInt BIG_ENDIAN_INT =
        ValueLayout.JAVA_INT_UNALIGNED.withOrder(ByteOrder.BIG_ENDIAN);
    private static final ResponseHeaders OK_TRAILERS =
        ResponseHeaders.builder().add("grpc-status", "0").build();
    private static final ResponseHeaders INVALID_ARGUMENT_TRAILERS =
        ResponseHeaders.builder().add("grpc-status", "3").build();

    @Post("/benchmark.BenchmarkService/GetSum")
    public Response getSum(
        @DecodedBody(GetSumDecoder.class) long decoded
    ) {
        if ((int) (decoded >>> 32) < 0) {
            return failure(INVALID_ARGUMENT_TRAILERS);
        }
        return replies((int) decoded, 1);
    }

    @Post("/benchmark.BenchmarkService/StreamSum")
    public Response streamSum(
        @DecodedBody(StreamSumDecoder.class) long decoded
    ) {
        int count = (int) (decoded >>> 32);
        if (count < 0 || count > MAX_STREAM_REPLIES) {
            return failure(INVALID_ARGUMENT_TRAILERS);
        }
        return replies((int) decoded, count);
    }

    private static Response replies(int first, int count) {
        if (count == 0) {
            return new Response(200, CONTENT_TYPE, null)
                .withTrailers(OK_TRAILERS);
        }
        int length = encodedLength(first, count);
        StreamingBody body = StreamingBody.of(
            length, new ReplyReader(first, count));
        return Response.stream(CONTENT_TYPE, body)
            .withTrailers(OK_TRAILERS);
    }

    private static Response failure(ResponseHeaders trailers) {
        return new Response(200, CONTENT_TYPE, null)
            .withTrailers(trailers);
    }

    /**
     * Returns {@code count << 32 | sum}. The canonical requests contain only
     * int32 varints, but unknown fixed- and length-delimited fields are skipped
     * according to the protobuf wire format.
     */
    private static long decodeRequest(
        MemorySegment source,
        long start,
        long length,
        boolean includeCount
    ) {
        if (source == null || length < 5 || start < 0
            || start > source.byteSize() - length) {
            throw new IllegalArgumentException("truncated gRPC frame");
        }
        if (source.get(ValueLayout.JAVA_BYTE, start) != 0) {
            throw new IllegalArgumentException(
                "compressed gRPC requests are unsupported");
        }
        int messageLength = source.get(BIG_ENDIAN_INT, start + 1);
        if (messageLength < 0 || messageLength != length - 5) {
            throw new IllegalArgumentException("invalid gRPC frame length");
        }

        long cursor = start + 5;
        long end = cursor + messageLength;
        int a = 0;
        int b = 0;
        int count = 0;
        while (cursor < end) {
            long key = 0;
            int shift = 0;
            int current;
            do {
                if (cursor == end || shift >= 35) {
                    throw new IllegalArgumentException("invalid protobuf key");
                }
                current = source.get(
                    ValueLayout.JAVA_BYTE, cursor++) & 0xff;
                key |= (long) (current & 0x7f) << shift;
                shift += 7;
            } while ((current & 0x80) != 0);

            int field = (int) (key >>> 3);
            int wireType = (int) key & 7;
            if (field == 0) {
                throw new IllegalArgumentException("invalid protobuf field");
            }
            if (wireType == 0) {
                long value = 0;
                shift = 0;
                do {
                    if (cursor == end || shift >= 70) {
                        throw new IllegalArgumentException(
                            "invalid protobuf varint");
                    }
                    current = source.get(
                        ValueLayout.JAVA_BYTE, cursor++) & 0xff;
                    value |= (long) (current & 0x7f) << shift;
                    shift += 7;
                } while ((current & 0x80) != 0);
                if (field == 1) {
                    a = (int) value;
                } else if (field == 2) {
                    b = (int) value;
                } else if (field == 3 && includeCount) {
                    count = (int) value;
                }
                continue;
            }

            long skipped = switch (wireType) {
                case 1 -> 8;
                case 2 -> {
                    long value = 0;
                    shift = 0;
                    do {
                        if (cursor == end || shift >= 70) {
                            throw new IllegalArgumentException(
                                "invalid protobuf length");
                        }
                        current = source.get(
                            ValueLayout.JAVA_BYTE, cursor++) & 0xff;
                        value |= (long) (current & 0x7f) << shift;
                        shift += 7;
                    } while ((current & 0x80) != 0);
                    yield value;
                }
                case 5 -> 4;
                default -> throw new IllegalArgumentException(
                    "unsupported protobuf wire type");
            };
            if (skipped < 0 || skipped > end - cursor) {
                throw new IllegalArgumentException(
                    "truncated protobuf field");
            }
            cursor += skipped;
        }
        int sum = a + b;
        return ((long) count << 32) | (sum & 0xffff_ffffL);
    }

    public static final class GetSumDecoder implements LongBodyDecoder {
        @Override
        public long decode(
            MemorySegment source,
            long offset,
            long length
        ) {
            try {
                return decodeRequest(source, offset, length, false);
            } catch (IllegalArgumentException invalid) {
                return INVALID_REQUEST;
            }
        }
    }

    public static final class StreamSumDecoder implements LongBodyDecoder {
        @Override
        public long decode(
            MemorySegment source,
            long offset,
            long length
        ) {
            try {
                return decodeRequest(source, offset, length, true);
            } catch (IllegalArgumentException invalid) {
                return INVALID_REQUEST;
            }
        }
    }

    private static int encodedLength(int first, int count) {
        long length = 0;
        for (int index = 0; index < count; index++) {
            length += 6L + varintLength(first + index);
        }
        if (length > Integer.MAX_VALUE) {
            throw new IllegalArgumentException("gRPC response is too large");
        }
        return (int) length;
    }

    private static int varintLength(int value) {
        if (value < 0) {
            return 10;
        }
        int bits = Integer.SIZE - Integer.numberOfLeadingZeros(value);
        return Math.max(1, (bits + 6) / 7);
    }

    private static final class ReplyReader implements StreamingBody.Reader {
        private final int first;
        private final int count;
        private int index;
        private long carryLow;
        private long carryHigh;
        private int carryOffset;
        private int carryLength;

        private ReplyReader(int first, int count) {
            this.first = first;
            this.count = count;
        }

        @Override
        public int read(MemorySegment destination) {
            int capacity = Math.toIntExact(destination.byteSize());
            int output = 0;
            while (output < capacity && carryOffset < carryLength) {
                destination.set(
                    ValueLayout.JAVA_BYTE,
                    output++,
                    carryByte(carryOffset++)
                );
            }
            if (carryOffset == carryLength) {
                carryOffset = 0;
                carryLength = 0;
            }

            while (output < capacity && index < count) {
                int result = first + index;
                int frameLength = 6 + varintLength(result);
                if (capacity - output >= frameLength) {
                    output += writeFrame(destination, output, result);
                    index++;
                    continue;
                }
                encodeCarry(result);
                index++;
                while (output < capacity && carryOffset < carryLength) {
                    destination.set(
                        ValueLayout.JAVA_BYTE,
                        output++,
                        carryByte(carryOffset++)
                    );
                }
                if (carryOffset == carryLength) {
                    carryOffset = 0;
                    carryLength = 0;
                }
            }
            return output == 0 ? -1 : output;
        }

        private static int writeFrame(
            MemorySegment destination,
            int offset,
            int result
        ) {
            int valueLength = varintLength(result);
            destination.set(ValueLayout.JAVA_BYTE, offset, (byte) 0);
            destination.set(BIG_ENDIAN_INT, offset + 1, 1 + valueLength);
            destination.set(ValueLayout.JAVA_BYTE, offset + 5, (byte) 8);
            long value = result;
            int cursor = offset + 6;
            while ((value & ~0x7fL) != 0) {
                destination.set(
                    ValueLayout.JAVA_BYTE,
                    cursor++,
                    (byte) ((value & 0x7f) | 0x80)
                );
                value >>>= 7;
            }
            destination.set(
                ValueLayout.JAVA_BYTE, cursor++, (byte) value);
            return cursor - offset;
        }

        private void encodeCarry(int result) {
            carryLow = 0;
            carryHigh = 0;
            carryOffset = 0;
            int valueLength = varintLength(result);
            int cursor = 0;
            putCarry(cursor++, 0);
            int messageLength = 1 + valueLength;
            putCarry(cursor++, messageLength >>> 24);
            putCarry(cursor++, messageLength >>> 16);
            putCarry(cursor++, messageLength >>> 8);
            putCarry(cursor++, messageLength);
            putCarry(cursor++, 8);
            long value = result;
            while ((value & ~0x7fL) != 0) {
                putCarry(cursor++, (int) ((value & 0x7f) | 0x80));
                value >>>= 7;
            }
            putCarry(cursor++, (int) value);
            carryLength = cursor;
        }

        private void putCarry(int offset, int value) {
            if (offset < Long.BYTES) {
                carryLow |= (long) (value & 0xff) << (offset * 8);
            } else {
                carryHigh |= (long) (value & 0xff)
                    << ((offset - Long.BYTES) * 8);
            }
        }

        private byte carryByte(int offset) {
            long word = offset < Long.BYTES ? carryLow : carryHigh;
            int shift = (offset & (Long.BYTES - 1)) * 8;
            return (byte) (word >>> shift);
        }
    }
}
