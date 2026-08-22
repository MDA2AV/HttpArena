package com.httparena;

import jakarta.inject.Inject;
import jakarta.ws.rs.GET;
import jakarta.ws.rs.Path;
import jakarta.ws.rs.Produces;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

import java.sql.Connection;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

/**
 * The fortunes profile: 200 rows from Postgres, one row appended in memory,
 * sorted, and rendered per request.
 *
 * This entry is `tuned`, which the profile allows to render "any rendering
 * strategy, including hand-rolled string concatenation" - so this builds the
 * page into a StringBuilder rather than pulling in a template engine. What
 * tuned does not relax is the rest: the query, the appended row, the sort and
 * the escaping all happen per request, and nothing is cached.
 *
 * The escape is the profile's load-bearing check - row 11 of the seed carries
 * a <script> tag and has to leave here as text.
 */
@Path("/fortunes")
public class FortunesResource {

    private static final String RUNTIME = "Additional fortune added at request time.";

    @Inject
    Db db;

    private record Fortune(int id, String message) {}

    private static void escape(StringBuilder out, String s) {
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '&' -> out.append("&amp;");
                case '<' -> out.append("&lt;");
                case '>' -> out.append("&gt;");
                case '"' -> out.append("&quot;");
                case '\'' -> out.append("&#39;");
                default -> out.append(c);
            }
        }
    }

    @GET
    @Produces(MediaType.TEXT_HTML + ";charset=utf-8")
    public Response fortunes() {
        if (db.pool() == null) {
            return Response.serverError().type(MediaType.TEXT_PLAIN).entity("DB not available").build();
        }
        List<Fortune> fortunes = new ArrayList<>(201);
        try (Connection conn = db.pool().getConnection();
             Statement stmt = conn.createStatement();
             ResultSet rs = stmt.executeQuery("SELECT id, message FROM fortune")) {
            while (rs.next()) fortunes.add(new Fortune(rs.getInt(1), rs.getString(2)));
        } catch (Exception e) {
            return Response.serverError().type(MediaType.TEXT_PLAIN).entity("query failed").build();
        }
        fortunes.add(new Fortune(0, RUNTIME));
        // Ordinal, not locale aware: the seed carries em-dashes and collation
        // rules would order them in a way the profile does not ask for.
        fortunes.sort(Comparator.comparing(Fortune::message));

        StringBuilder out = new StringBuilder(32768);
        out.append("<!DOCTYPE html><html><head><title>Fortunes</title></head><body><table>")
           .append("<tr><th>id</th><th>message</th></tr>");
        for (Fortune f : fortunes) {
            out.append("<tr><td>").append(f.id()).append("</td><td>");
            escape(out, f.message());
            out.append("</td></tr>");
        }
        out.append("</table></body></html>");
        return Response.ok(out.toString()).build();
    }
}
