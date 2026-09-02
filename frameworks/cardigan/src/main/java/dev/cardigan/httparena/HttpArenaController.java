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

    @Get("/baseline2")
    public Response baseline2(
            @QueryParam("a") int a,
            @QueryParam("b") int b) {
        return Response.text((long) a + b);
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
