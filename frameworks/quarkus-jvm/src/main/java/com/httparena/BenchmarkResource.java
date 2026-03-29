package com.httparena;

import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.smallrye.common.annotation.NonBlocking;
import jakarta.annotation.PostConstruct;
import jakarta.ws.rs.*;
import jakarta.ws.rs.core.MediaType;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URI;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.*;

@Path("/")
public class BenchmarkResource {

    private final ObjectMapper mapper = new ObjectMapper();
    private List<Map<String, Object>> dataset;
    private byte[] largeJsonResponse;
    private boolean dbAvailable = false;
    private static final String DB_QUERY = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50";
    private static final String PG_QUERY = "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count FROM items WHERE price BETWEEN ? AND ? LIMIT 50";
    private static final ThreadLocal<Connection> tlConn = new ThreadLocal<>();
    private static final ThreadLocal<PreparedStatement> tlStmt = new ThreadLocal<>();
    private HikariDataSource pgPool;

    @PostConstruct
    public void init() throws IOException {
        String path = System.getenv("DATASET_PATH");
        if (path == null) path = "/data/dataset.json";
        File f = new File(path);
        if (f.exists()) {
            dataset = mapper.readValue(f, new TypeReference<>() {});
        }
        File largef = new File("/data/dataset-large.json");
        if (largef.exists()) {
            List<Map<String, Object>> largeDataset = mapper.readValue(largef, new TypeReference<>() {});
            List<Map<String, Object>> largeItems = new ArrayList<>(largeDataset.size());
            for (Map<String, Object> item : largeDataset) {
                Map<String, Object> processed = new LinkedHashMap<>(item);
                double price = ((Number) item.get("price")).doubleValue();
                int quantity = ((Number) item.get("quantity")).intValue();
                processed.put("total", Math.round(price * quantity * 100.0) / 100.0);
                largeItems.add(processed);
            }
            largeJsonResponse = mapper.writeValueAsBytes(Map.of("items", largeItems, "count", largeItems.size()));
        }
        // Check SQLite database availability
        File dbFile = new File("/data/benchmark.db");
        if (dbFile.exists()) {
            try {
                Connection test = DriverManager.getConnection("jdbc:sqlite:file:/data/benchmark.db?mode=ro&immutable=1");
                test.close();
                dbAvailable = true;
            } catch (Exception ignored) {}
        }
        // Initialize PostgreSQL connection pool from DATABASE_URL
        String pgUrl = System.getenv("DATABASE_URL");
        if (pgUrl != null && !pgUrl.isEmpty()) {
            try {
                URI uri = new URI(pgUrl.replace("postgres://", "postgresql://"));
                String host = uri.getHost();
                int port = uri.getPort() > 0 ? uri.getPort() : 5432;
                String database = uri.getPath().substring(1);
                String[] userInfo = uri.getUserInfo().split(":");
                HikariConfig config = new HikariConfig();
                config.setDriverClassName("org.postgresql.Driver");
                config.setJdbcUrl("jdbc:postgresql://" + host + ":" + port + "/" + database);
                config.setUsername(userInfo[0]);
                config.setPassword(userInfo.length > 1 ? userInfo[1] : "");
                config.setMaximumPoolSize(64);
                config.setMinimumIdle(16);
                pgPool = new HikariDataSource(config);
            } catch (Exception ignored) {}
        }
    }

    @GET
    @Path("/pipeline")
    @Produces(MediaType.TEXT_PLAIN)
    @NonBlocking
    public String pipeline() {
        return "ok";
    }

    @GET
    @Path("/baseline11")
    @Produces(MediaType.TEXT_PLAIN)
    @NonBlocking
    public int baselineGet(@QueryParam("a") int a, @QueryParam("b") int b) {
        return a + b;
    }

    @POST
    @Path("/baseline11")
    @Consumes(MediaType.TEXT_PLAIN)
    @Produces(MediaType.TEXT_PLAIN)
    @NonBlocking
    public int baselinePost(@QueryParam("a") int a, @QueryParam("b") int b, int body) {
        return a + b + body;
    }

    @POST
    @Path("/upload")
    @Consumes(MediaType.APPLICATION_OCTET_STREAM)
    @Produces(MediaType.TEXT_PLAIN)
    public long upload(InputStream body) throws IOException {
        return body.transferTo(OutputStream.nullOutputStream());
    }

    @GET
    @Path("/baseline2")
    @Produces(MediaType.TEXT_PLAIN)
    @NonBlocking
    public int baseline2(@QueryParam("a") int a, @QueryParam("b") int b) {
        return a + b;
    }

    @GET
    @Path("/db")
    @Produces(MediaType.APPLICATION_JSON)
    public jakarta.ws.rs.core.Response db(@QueryParam("min") String minParam, @QueryParam("max") String maxParam) {
        if (!dbAvailable)
            return jakarta.ws.rs.core.Response.ok("{\"items\":[],\"count\":0}".getBytes())
                .header("Content-Type", "application/json").build();
        PreparedStatement stmt = getDbStmt();
        if (stmt == null)
            return jakarta.ws.rs.core.Response.ok("{\"items\":[],\"count\":0}".getBytes())
                .header("Content-Type", "application/json").build();
        double minPrice = 10.0, maxPrice = 50.0;
        if (minParam != null) try { minPrice = Double.parseDouble(minParam); } catch (NumberFormatException ignored) {}
        if (maxParam != null) try { maxPrice = Double.parseDouble(maxParam); } catch (NumberFormatException ignored) {}
        try {
            stmt.setDouble(1, minPrice);
            stmt.setDouble(2, maxPrice);
            ResultSet rs = stmt.executeQuery();
            List<Map<String, Object>> items = new ArrayList<>();
            while (rs.next()) {
                List<String> tags = mapper.readValue(rs.getString(7), new TypeReference<>() {});
                Map<String, Object> row = new LinkedHashMap<>();
                row.put("id", rs.getInt(1));
                row.put("name", rs.getString(2));
                row.put("category", rs.getString(3));
                row.put("price", rs.getDouble(4));
                row.put("quantity", rs.getInt(5));
                row.put("active", rs.getInt(6) == 1);
                row.put("tags", tags);
                row.put("rating", Map.of("score", rs.getDouble(8), "count", rs.getInt(9)));
                items.add(row);
            }
            rs.close();
            return jakarta.ws.rs.core.Response.ok(mapper.writeValueAsBytes(Map.of("items", items, "count", items.size())))
                .header("Content-Type", "application/json").build();
        } catch (Exception e) {
            return jakarta.ws.rs.core.Response.ok("{\"items\":[],\"count\":0}".getBytes())
                .header("Content-Type", "application/json").build();
        }
    }

    @GET
    @Path("/async-db")
    @Produces(MediaType.APPLICATION_JSON)
    public jakarta.ws.rs.core.Response asyncDb(@QueryParam("min") String minParam, @QueryParam("max") String maxParam) {
        if (pgPool == null)
            return jakarta.ws.rs.core.Response.ok("{\"items\":[],\"count\":0}".getBytes())
                .header("Content-Type", "application/json").build();
        double minPrice = 10.0, maxPrice = 50.0;
        if (minParam != null) try { minPrice = Double.parseDouble(minParam); } catch (NumberFormatException ignored) {}
        if (maxParam != null) try { maxPrice = Double.parseDouble(maxParam); } catch (NumberFormatException ignored) {}
        try (Connection conn = pgPool.getConnection()) {
            PreparedStatement stmt = conn.prepareStatement(PG_QUERY);
            stmt.setDouble(1, minPrice);
            stmt.setDouble(2, maxPrice);
            ResultSet rs = stmt.executeQuery();
            List<Map<String, Object>> items = new ArrayList<>();
            while (rs.next()) {
                List<String> tags = mapper.readValue(rs.getString(7), new TypeReference<>() {});
                Map<String, Object> row = new LinkedHashMap<>();
                row.put("id", rs.getInt(1));
                row.put("name", rs.getString(2));
                row.put("category", rs.getString(3));
                row.put("price", rs.getDouble(4));
                row.put("quantity", rs.getInt(5));
                row.put("active", rs.getBoolean(6));
                row.put("tags", tags);
                row.put("rating", Map.of("score", rs.getDouble(8), "count", rs.getInt(9)));
                items.add(row);
            }
            rs.close();
            stmt.close();
            return jakarta.ws.rs.core.Response.ok(mapper.writeValueAsBytes(Map.of("items", items, "count", items.size())))
                .header("Content-Type", "application/json").build();
        } catch (Exception e) {
            return jakarta.ws.rs.core.Response.ok("{\"items\":[],\"count\":0}".getBytes())
                .header("Content-Type", "application/json").build();
        }
    }

    @GET
    @Path("/json")
    @Produces(MediaType.APPLICATION_JSON)
    @NonBlocking
    public Map<String, Object> json() {
        List<Map<String, Object>> items = new ArrayList<>(dataset.size());
        for (Map<String, Object> item : dataset) {
            Map<String, Object> processed = new LinkedHashMap<>(item);
            double price = ((Number) item.get("price")).doubleValue();
            int quantity = ((Number) item.get("quantity")).intValue();
            processed.put("total", Math.round(price * quantity * 100.0) / 100.0);
            items.add(processed);
        }
        return Map.of("items", items, "count", items.size());
    }

    @GET
    @Path("/compression")
    @Produces(MediaType.APPLICATION_JSON)
    @NonBlocking
    public byte[] compression() {
        return largeJsonResponse;
    }

    private PreparedStatement getDbStmt() {
        PreparedStatement stmt = tlStmt.get();
        if (stmt != null) return stmt;
        try {
            Connection conn = DriverManager.getConnection("jdbc:sqlite:file:/data/benchmark.db?mode=ro&immutable=1");
            conn.createStatement().execute("PRAGMA mmap_size=268435456");
            stmt = conn.prepareStatement(DB_QUERY);
            tlConn.set(conn);
            tlStmt.set(stmt);
        } catch (Exception e) {
            return null;
        }
        return stmt;
    }

}
