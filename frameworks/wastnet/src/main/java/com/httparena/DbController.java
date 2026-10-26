package com.httparena;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;

import io.github.wycst.wastnet.http.annotation.ContentType;
import io.github.wycst.wastnet.http.annotation.Endpoint;
import io.github.wycst.wastnet.http.annotation.RequestParam;
import io.github.wycst.wastnet.http.annotation.RestController;
import io.github.wycst.wast.json.JSON;

import java.net.URI;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * TechEmpower-style DB profiles against the HttpArena Postgres sidecar.
 * async-db queries the {@code items} table (price BETWEEN ? AND ? LIMIT ?) and
 * returns {"items":[...],"count":N}; fortunes renders the standard fortune table
 * as HTML. The pool is created lazily so this controller still loads (and other
 * endpoints stay healthy) when the DB is unreachable.
 */
@RestController
public class DbController {

    // This repo's async-db queries the `items` table (price BETWEEN min AND max, LIMIT),
    // matching the contract in scripts/validate.sh and the working quarkus-jvm reference.
    private static final String ITEMS_QUERY =
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count "
            + "FROM items WHERE price BETWEEN ? AND ? LIMIT ?";
    private static final String FORTUNE_QUERY = "SELECT id, message FROM fortune";

    // DATABASE_URL (postgres://user:pass@host:port/db) is injected by the harness; parsed once here.
    private static final URI DB_URI = dbUri();
    private static final String JDBC_URL = jdbcUrl(DB_URI);
    private static final String DB_USER = dbUser(DB_URI);
    private static final String DB_PASS = dbPass(DB_URI);
    // Match quarkus-jvm's pool sizing (DATABASE_MAX_CONN / 4) for an apples-to-apples comparison.
    private static final int MAX_POOL = Math.max(1, envInt("DATABASE_MAX_CONN", 256) / 4);

    private static volatile HikariDataSource pool;

    private static String env(String key, String def) {
        String v = System.getenv(key);
        return (v != null && !v.isEmpty()) ? v : def;
    }

    private static int envInt(String key, int def) {
        String v = System.getenv(key);
        if (v == null || v.isEmpty()) {
            return def;
        }
        try {
            return Integer.parseInt(v.trim());
        } catch (NumberFormatException e) {
            return def;
        }
    }

    private static URI dbUri() {
        String dbUrl = env("DATABASE_URL", "postgres://bench:bench@localhost:5432/benchmark");
        try {
            return new URI(dbUrl.replace("postgres://", "postgresql://"));
        } catch (Exception e) {
            return URI.create("postgresql://localhost:5432/benchmark");
        }
    }

    private static String jdbcUrl(URI uri) {
        if (uri.getScheme() != null && uri.getScheme().startsWith("jdbc")) {
            return uri.toString();
        }
        String path = (uri.getPath() == null || uri.getPath().isEmpty()) ? "/benchmark" : uri.getPath();
        String host = uri.getHost() == null ? "localhost" : uri.getHost();
        int port = uri.getPort() > 0 ? uri.getPort() : 5432;
        return "jdbc:postgresql://" + host + ":" + port + path;
    }

    private static String dbUser(URI uri) {
        String ui = uri.getUserInfo();
        if (ui != null && !ui.isEmpty()) {
            return ui.split(":")[0];
        }
        return "bench";
    }

    private static String dbPass(URI uri) {
        String ui = uri.getUserInfo();
        if (ui != null && !ui.isEmpty()) {
            String[] parts = ui.split(":");
            return parts.length > 1 ? parts[1] : "";
        }
        return "bench";
    }

    private static HikariDataSource pool() {
        HikariDataSource ds = pool;
        if (ds == null) {
            synchronized (DbController.class) {
                ds = pool;
                if (ds == null) {
                    HikariConfig cfg = new HikariConfig();
                    // Explicit driver class: HikariCP cannot always auto-discover the
                    // Postgres driver inside a shaded fat jar, which surfaces as a silent
                    // "No suitable driver" connection failure.
                    cfg.setDriverClassName("org.postgresql.Driver");
                    cfg.setJdbcUrl(JDBC_URL);
                    cfg.setUsername(DB_USER);
                    cfg.setPassword(DB_PASS);
                    cfg.setMaximumPoolSize(MAX_POOL);
                    cfg.setMinimumIdle(Math.min(16, MAX_POOL));
                    cfg.setInitializationFailTimeout(-1);
                    try {
                        ds = new HikariDataSource(cfg);
                    } catch (Throwable t) {
                        System.err.println("[DbController] Hikari pool init failed (url=" + JDBC_URL
                                + ", user=" + DB_USER + "): " + t);
                        t.printStackTrace();
                        throw new IllegalStateException("hikari pool unavailable", t);
                    }
                    pool = ds;
                }
            }
        }
        return ds;
    }

    // GET /async-db?min=&max=&limit=  (also accepts `queries` as an alias for limit,
    // matching the canonical TechEmpower parameter name some load generators send).
    // Returns {"items":[...],"count":N}; empty list when no rows match or the DB is down.
    @Endpoint(value = "/async-db", responseType = ContentType.JSON)
    public Map<String, Object> asyncDb(
            @RequestParam(value = "min", required = false, defaultValue = "10") int min,
            @RequestParam(value = "max", required = false, defaultValue = "50") int max,
            @RequestParam(value = "limit", required = false, defaultValue = "50") int limit,
            @RequestParam(value = "queries", required = false, defaultValue = "-1") int queries) {
        int n = Math.max(1, Math.min(50, queries > 0 ? queries : limit));
        List<Map<String, Object>> items = new ArrayList<Map<String, Object>>(n);
        try (Connection conn = pool().getConnection()) {
            try (PreparedStatement ps = conn.prepareStatement(ITEMS_QUERY)) {
                ps.setInt(1, min);
                ps.setInt(2, max);
                ps.setInt(3, n);
                try (ResultSet rs = ps.executeQuery()) {
                    // Column order matches ITEMS_QUERY:
                    // 1=id 2=name 3=category 4=price 5=quantity 6=active 7=tags 8=rating_score 9=rating_count
                    while (rs.next()) {
                        Map<String, Object> row = new LinkedHashMap<String, Object>(8);
                        row.put("id", rs.getInt(1));
                        row.put("name", rs.getString(2));
                        row.put("category", rs.getString(3));
                        row.put("price", rs.getInt(4));
                        row.put("quantity", rs.getInt(5));
                        row.put("active", rs.getBoolean(6));
                        String tagsJson = rs.getString(7);
                        row.put("tags", tagsJson == null ? new ArrayList<String>(0)
                                : JSON.parseArray(tagsJson, String.class));
                        Map<String, Object> rating = new LinkedHashMap<String, Object>(2);
                        rating.put("score", rs.getInt(8));
                        rating.put("count", rs.getInt(9));
                        row.put("rating", rating);
                        items.add(row);
                    }
                }
            }
        } catch (Exception e) {
            // Contract: return empty list (count=0) if the DB is unavailable, but log for diagnosis.
            System.err.println("[async-db] query failed: " + e);
            e.printStackTrace();
            items.clear();
        }
        Map<String, Object> result = new LinkedHashMap<String, Object>();
        result.put("items", items);
        result.put("count", items.size());
        return result;
    }

    @Endpoint(value = "/fortunes", responseType = ContentType.HTML)
    public String fortunes() {
        List<Fortune> list = new ArrayList<Fortune>(201);
        try (Connection conn = pool().getConnection()) {
            try (PreparedStatement ps = conn.prepareStatement(FORTUNE_QUERY)) {
                try (ResultSet rs = ps.executeQuery()) {
                    while (rs.next()) {
                        list.add(new Fortune(rs.getInt(1), rs.getString(2)));
                    }
                }
            }
        } catch (Exception e) {
            System.err.println("[fortunes] query failed: " + e);
            e.printStackTrace();
            return "<!DOCTYPE html><html><body><h1>fortunes DB error</h1><pre>"
                    + escapeHtml(e.toString()) + "</pre></body></html>";
        }
        list.add(new Fortune(0, "Additional fortune added at request time."));
        list.sort((a, b) -> a.message.compareTo(b.message));

        StringBuilder out = new StringBuilder(32768);
        out.append("<!DOCTYPE html><html><head><title>Fortunes</title></head><body>")
           .append("<table><tr><th>id</th><th>message</th></tr>");
        for (Fortune f : list) {
            out.append("<tr><td>").append(f.id).append("</td><td>");
            escape(out, f.message);
            out.append("</td></tr>");
        }
        out.append("</table></body></html>");
        return out.toString();
    }

    private static void escape(StringBuilder out, String s) {
        if (s == null) {
            return;
        }
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '&': out.append("&amp;"); break;
                case '<': out.append("&lt;"); break;
                case '>': out.append("&gt;"); break;
                case '"': out.append("&quot;"); break;
                case '\'': out.append("&#39;"); break;
                default: out.append(c);
            }
        }
    }

    private static String escapeHtml(String s) {
        if (s == null) {
            return "";
        }
        StringBuilder b = new StringBuilder(s.length());
        escape(b, s);
        return b.toString();
    }

    private static final class Fortune {
        final int id;
        final String message;
        Fortune(int id, String message) {
            this.id = id;
            this.message = message;
        }
    }
}
