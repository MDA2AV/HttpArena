package com.httparena;

import com.fasterxml.jackson.databind.ObjectMapper;

import jakarta.inject.Inject;
import jakarta.ws.rs.*;
import jakarta.ws.rs.core.MediaType;
import jakarta.ws.rs.core.Response;

import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.util.*;
import java.util.concurrent.ConcurrentHashMap;

/**
 * The crud profile: paginated list, cache-aside read, upsert, and update with
 * invalidation.
 *
 * The cache is an in-process map rather than the Redis sidecar. The profile
 * allows either, and this entry is one JVM: a single heap already gives every
 * request the same cache, which is what the sidecar exists to provide for the
 * runtimes that run a process per core.
 */
@Path("/crud/items")
@Produces(MediaType.APPLICATION_JSON)
public class CrudResource {

    private static final String COLUMNS =
        "id, name, category, price, quantity, active, tags, rating_score, rating_count";
    private static final long TTL_NANOS = 200_000_000L;   // 200ms, as the profile specifies

    private record Cached(String json, long expiresAt) {}

    private final ObjectMapper mapper = new ObjectMapper();
    private final ConcurrentHashMap<Integer, Cached> cache = new ConcurrentHashMap<>();

    @Inject
    Db db;

    private Map<String, Object> shape(ResultSet rs) throws Exception {
        Map<String, Object> item = new LinkedHashMap<>();
        item.put("id", rs.getInt("id"));
        item.put("name", rs.getString("name"));
        item.put("category", rs.getString("category"));
        item.put("price", rs.getInt("price"));
        item.put("quantity", rs.getInt("quantity"));
        item.put("active", rs.getBoolean("active"));
        item.put("tags", mapper.readValue(rs.getString("tags"), List.class));
        item.put("rating", Map.of("score", rs.getInt("rating_score"), "count", rs.getInt("rating_count")));
        return item;
    }

    private static Response unavailable() {
        return Response.serverError().entity(Map.of("error", "DB not available")).build();
    }

    @GET
    public Response list(@QueryParam("category") String category,
                         @QueryParam("page") Integer pageParam,
                         @QueryParam("limit") Integer limitParam) {
        if (db.pool() == null) return unavailable();
        String cat = category == null ? "electronics" : category;
        int page = pageParam == null ? 1 : Math.max(1, pageParam);
        int limit = limitParam == null ? 10 : Math.min(50, Math.max(1, limitParam));

        List<Map<String, Object>> items = new ArrayList<>(limit);
        try (Connection conn = db.pool().getConnection();
             PreparedStatement st = conn.prepareStatement(
                 "SELECT " + COLUMNS + " FROM items WHERE category = ? ORDER BY id LIMIT ? OFFSET ?")) {
            st.setString(1, cat);
            st.setInt(2, limit);
            st.setInt(3, (page - 1) * limit);
            try (ResultSet rs = st.executeQuery()) {
                while (rs.next()) items.add(shape(rs));
            }
        } catch (Exception e) {
            return Response.serverError().entity(Map.of("error", "query failed")).build();
        }
        return Response.ok(Map.of("items", items, "total", items.size(), "page", page, "limit", limit)).build();
    }

    @GET
    @jakarta.ws.rs.Path("/{id}")
    public Response read(@PathParam("id") int id) {
        if (db.pool() == null) return unavailable();

        Cached hit = cache.get(id);
        if (hit != null && hit.expiresAt() > System.nanoTime()) {
            return Response.ok(hit.json()).header("X-Cache", "HIT").build();
        }
        try (Connection conn = db.pool().getConnection();
             PreparedStatement st = conn.prepareStatement(
                 "SELECT " + COLUMNS + " FROM items WHERE id = ? LIMIT 1")) {
            st.setInt(1, id);
            try (ResultSet rs = st.executeQuery()) {
                if (!rs.next()) return Response.status(404).build();
                String json = mapper.writeValueAsString(shape(rs));
                cache.put(id, new Cached(json, System.nanoTime() + TTL_NANOS));
                return Response.ok(json).header("X-Cache", "MISS").build();
            }
        } catch (Exception e) {
            return Response.serverError().entity(Map.of("error", "query failed")).build();
        }
    }

    @POST
    @Consumes(MediaType.APPLICATION_JSON)
    public Response create(Map<String, Object> body) {
        if (db.pool() == null) return unavailable();
        try (Connection conn = db.pool().getConnection();
             PreparedStatement st = conn.prepareStatement(
                 "INSERT INTO items (id, name, category, price, quantity, active, tags, rating_score, rating_count) "
                 + "VALUES (?, ?, ?, ?, ?, true, '[\"bench\"]', 0, 0) "
                 + "ON CONFLICT (id) DO UPDATE SET name = ?, price = ?, quantity = ? RETURNING id")) {
            int id = ((Number) body.getOrDefault("id", 0)).intValue();
            String name = String.valueOf(body.getOrDefault("name", "New Product"));
            int price = ((Number) body.getOrDefault("price", 0)).intValue();
            int quantity = ((Number) body.getOrDefault("quantity", 0)).intValue();
            st.setInt(1, id);
            st.setString(2, name);
            st.setString(3, String.valueOf(body.getOrDefault("category", "test")));
            st.setInt(4, price);
            st.setInt(5, quantity);
            st.setString(6, name);
            st.setInt(7, price);
            st.setInt(8, quantity);
            try (ResultSet rs = st.executeQuery()) {
                if (!rs.next()) return Response.serverError().entity(Map.of("error", "insert failed")).build();
                Map<String, Object> out = new LinkedHashMap<>();
                out.put("id", rs.getInt(1));
                out.put("name", name);
                out.put("category", body.get("category"));
                out.put("price", price);
                out.put("quantity", quantity);
                return Response.status(201).entity(out).build();
            }
        } catch (Exception e) {
            return Response.serverError().entity(Map.of("error", "insert failed")).build();
        }
    }

    @PUT
    @jakarta.ws.rs.Path("/{id}")
    @Consumes(MediaType.APPLICATION_JSON)
    public Response update(@PathParam("id") int id, Map<String, Object> body) {
        if (db.pool() == null) return unavailable();
        try (Connection conn = db.pool().getConnection();
             PreparedStatement st = conn.prepareStatement(
                 "UPDATE items SET name = ?, price = ?, quantity = ? WHERE id = ?")) {
            String name = String.valueOf(body.getOrDefault("name", "Updated"));
            int price = ((Number) body.getOrDefault("price", 0)).intValue();
            int quantity = ((Number) body.getOrDefault("quantity", 0)).intValue();
            st.setString(1, name);
            st.setInt(2, price);
            st.setInt(3, quantity);
            st.setInt(4, id);
            if (st.executeUpdate() == 0) return Response.status(404).build();
            cache.remove(id);
            Map<String, Object> out = new LinkedHashMap<>();
            out.put("id", id);
            out.put("name", name);
            out.put("price", price);
            out.put("quantity", quantity);
            return Response.ok(out).build();
        } catch (Exception e) {
            return Response.serverError().entity(Map.of("error", "update failed")).build();
        }
    }
}
