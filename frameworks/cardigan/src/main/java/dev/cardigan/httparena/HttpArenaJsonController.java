// SPDX-License-Identifier: MPL-2.0

package dev.cardigan.httparena;

import dev.cardigan.http.Get;
import dev.cardigan.http.QueryParam;
import dev.cardigan.http.Response;

/** Live JSON transformation endpoint used by HttpArena's TLS profile. */
public final class HttpArenaJsonController {
    private final HttpArenaDataset dataset;

    HttpArenaJsonController(HttpArenaDataset dataset) {
        this.dataset = dataset;
    }

    @Get("/json/{count}")
    public Response json(
            int count,
            @QueryParam(value = "m", defaultValue = 1) int multiplier) {
        if (count < 1 || count > dataset.size()) {
            return new Response(
                400, "text/plain", Response.CT_TEXT,
                "count must be between 1 and " + dataset.size());
        }
        return Response.encoded(
            "application/json", dataset.render(count, multiplier));
    }
}
