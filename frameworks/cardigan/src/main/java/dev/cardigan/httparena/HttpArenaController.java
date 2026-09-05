// SPDX-License-Identifier: MPL-2.0

package dev.cardigan.httparena;

import dev.cardigan.http.Get;
import dev.cardigan.http.Post;
import dev.cardigan.http.QueryParam;
import dev.cardigan.http.RequestBody;
import dev.cardigan.http.Response;

import java.lang.foreign.Arena;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.util.Arrays;

/** The small arithmetic endpoints shared by the HttpArena transports. */
public final class HttpArenaController {
    @Get("/baseline11")
    public Response baseline11(
            @QueryParam("a") int a,
            @QueryParam("b") int b) {
        return Response.text((long) a + b);
    }

    @Post("/baseline11")
    public Response baseline11(
            @QueryParam("a") int a,
            @QueryParam("b") int b,
            RequestBody body) {
        long sum = (long) a + b;
        try (Arena arena = Arena.ofConfined()) {
            MemorySegment scratch = arena.allocate(64);
            sum += readLong(body, scratch);
        }
        return Response.text(sum);
    }

    @Get("/pipeline")
    public Response pipeline() {
        return Response.text("ok");
    }

    @Get("/delay/{ms}")
    public Response delay(int ms) {
        // Handlers run on virtual threads, so this parks the virtual thread rather than a
        // carrier and the waits in flight are bounded by memory.
        if (ms > 0) {
            try {
                Thread.sleep(ms);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
            }
        }
        return Response.text((long) ms);
    }

    @Get("/baseline2")
    public Response baseline2(
            @QueryParam("a") int a,
            @QueryParam("b") int b) {
        return Response.text((long) a + b);
    }

    @Post("/echo")
    public Response echo(RequestBody body) {
        return Response.bytes(
            "application/octet-stream",
            readBody(body));
    }

    private static byte[] readBody(RequestBody body) {
        long declaredLength = body.length();
        if (declaredLength > Integer.MAX_VALUE) {
            throw new IllegalArgumentException("echo body is too large");
        }

        int initialCapacity = declaredLength >= 0
            ? (int) declaredLength
            : 16 * 1024;
        byte[] bytes = new byte[initialCapacity];
        int length = 0;
        while (declaredLength < 0 || length < initialCapacity) {
            if (length == bytes.length) {
                int nextCapacity = Math.max(1, bytes.length << 1);
                if (nextCapacity <= bytes.length) {
                    throw new IllegalArgumentException("echo body is too large");
                }
                bytes = Arrays.copyOf(bytes, nextCapacity);
            }
            int read = body.read(
                MemorySegment.ofArray(bytes).asSlice(
                    length, bytes.length - length));
            if (read < 0) {
                break;
            }
            length += read;
        }

        if (declaredLength >= 0 && length != initialCapacity) {
            throw new IllegalArgumentException(
                "echo body ended before its declared length");
        }
        return length == bytes.length ? bytes : Arrays.copyOf(bytes, length);
    }

    private static long readLong(RequestBody body, MemorySegment scratch) {
        long value = 0;
        boolean negative = false;
        boolean started = false;
        int count;
        while ((count = body.read(scratch)) >= 0) {
            for (int index = 0; index < count; index++) {
                byte current = scratch.get(ValueLayout.JAVA_BYTE, index);
                if (!started && (current == ' ' || current == '\t'
                        || current == '\r' || current == '\n')) {
                    continue;
                }
                if (!started && current == '-') {
                    negative = true;
                    started = true;
                    continue;
                }
                if (current < '0' || current > '9') {
                    throw new IllegalArgumentException(
                        "baseline body must be an integer");
                }
                started = true;
                value = value * 10 + current - '0';
            }
        }
        if (!started) {
            throw new IllegalArgumentException(
                "baseline body must be an integer");
        }
        return negative ? -value : value;
    }
}
