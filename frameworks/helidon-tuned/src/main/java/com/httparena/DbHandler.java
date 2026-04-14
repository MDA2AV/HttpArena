package com.httparena;

import java.net.URI;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.locks.ReentrantReadWriteLock;

import io.helidon.common.uri.UriQuery;
import io.helidon.http.Status;
import io.helidon.webserver.http.Handler;
import io.helidon.webserver.http.ServerRequest;
import io.helidon.webserver.http.ServerResponse;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;

import static com.httparena.Main.SERVER_HEADER;
import static io.helidon.http.HeaderValues.CONTENT_TYPE_JSON;

class DbHandler implements Handler {
    private static final Items EMPTY_ITEMS_RESPONSE = new Items(List.of(), 0);
    private static final String DB_QUERY =
            "SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count "
                    + "FROM items "
                    + "WHERE price "
                    + "BETWEEN ? AND ? "
                    + "LIMIT ?";

    private final ReentrantReadWriteLock databaseLock = new ReentrantReadWriteLock();
    private final boolean databaseConfigured;
    private final String dbUrl;

    private HikariDataSource database;

    DbHandler() {
        this.dbUrl = System.getenv("DATABASE_URL");
        databaseConfigured = dbUrl != null && !dbUrl.isEmpty();

        if (databaseConfigured) {
            this.database = initializeDatabase(dbUrl);
        }
    }

    @Override
    public void handle(ServerRequest req, ServerResponse res) {
        res.header(SERVER_HEADER);

        if (!databaseConfigured) {
            // if not configured, fail (maybe local invocation, or manual command line invocation)
            res.status(Status.INTERNAL_SERVER_ERROR_500)
                    .send();
            return;
        }

        res.header(SERVER_HEADER);
        res.header(CONTENT_TYPE_JSON);

        HikariDataSource dataSource = database();
        if (dataSource == null) {
            res.send(EMPTY_ITEMS_RESPONSE);
            return;
        }

        try {
            res.send(queryItems(req, dataSource));
        } catch (SQLException ignored) {
            resetDatabase(dataSource);
            res.send(EMPTY_ITEMS_RESPONSE);
        }
    }

    private static HikariDataSource initializeDatabase(String dbUrl) {
        int maxConnections = Integer.parseInt(System.getenv().getOrDefault("DATABASE_MAX_CONN", "64"));
        int minimumIdle = 10 <= maxConnections ? 10 : 1;

        // PostgreSQL connection pool
        try {
            URI uri = new URI(dbUrl.replace("postgres://", "postgresql://"));
            String host = uri.getHost();
            int port = uri.getPort() > 0 ? uri.getPort() : 5432;
            String database = uri.getPath().substring(1);
            String[] userInfo = uri.getUserInfo().split(":");
            HikariConfig config = new HikariConfig();
            config.setDriverClassName("org.postgresql.Driver");
            config.setJdbcUrl("jdbc:postgresql://" + host + ":" + port + "/" + database);
            config.setUsername(userInfo[0]);
            config.setPassword(userInfo.length > 1 ? userInfo[1] : "");
            config.setMaximumPoolSize(maxConnections);
            config.setMinimumIdle(minimumIdle);
            config.setReadOnly(true);
            return new HikariDataSource(config);
        } catch (Exception e) {
            return null;
        }
    }

    private Items queryItems(ServerRequest req, HikariDataSource dataSource) throws SQLException {
        try (Connection conn = dataSource.getConnection()) {
            UriQuery query = req.query();

            int min = query.first("min").map(Integer::parseInt).orElse(10);
            int max = query.first("max").map(Integer::parseInt).orElse(50);
            int limit = Math.min(Math.max(query.first("limit").map(Integer::parseInt).orElse(50), 1), 50);

            List<Item> items = new ArrayList<>(limit);

            try (PreparedStatement stmt = conn.prepareStatement(DB_QUERY)) {
                stmt.setInt(1, min);
                stmt.setInt(2, max);
                stmt.setInt(3, limit);

                try (ResultSet rs = stmt.executeQuery()) {

                    while (rs.next()) {
                        items.add(new Item(rs.getLong("id"),
                                           rs.getString("name"),
                                           rs.getString("category"),
                                           rs.getInt("price"),
                                           rs.getInt("quantity"),
                                           rs.getBoolean("active"),
                                           parseTags(rs.getString("tags")),
                                           new Rating(rs.getInt("rating_score"),
                                                      rs.getInt("rating_count"))));
                    }
                }
            }

            return new Items(items, items.size());
        }
    }

    private List<String> parseTags(String rawTags) {
        if (rawTags == null || rawTags.isBlank()) {
            return List.of();
        }

        String trimmed = rawTags.trim();
        if (trimmed.startsWith("[") && trimmed.endsWith("]")) {
            List<String> tags = new ArrayList<>();
            String body = trimmed.substring(1, trimmed.length() - 1).trim();
            if (body.isEmpty()) {
                return tags;
            }

            for (String token : body.split(",")) {
                String tag = token.trim();
                if (tag.length() >= 2 && tag.startsWith("\"") && tag.endsWith("\"")) {
                    tag = tag.substring(1, tag.length() - 1);
                }
                tags.add(tag);
            }
            return tags;
        }

        List<String> tags = new ArrayList<>();
        for (String tag : trimmed.split(",")) {
            tags.add(tag.trim());
        }
        return tags;
    }

    private HikariDataSource database() {
        databaseLock.readLock().lock();
        try {
            HikariDataSource existing = database;
            if (existing != null) {
                return existing;
            }
        } finally {
            databaseLock.readLock().unlock();
        }

        databaseLock.writeLock().lock();
        try {
            if (database == null) {
                database = initializeDatabase(dbUrl);
            }
            return database;
        } finally {
            databaseLock.writeLock().unlock();
        }
    }

    private void resetDatabase(HikariDataSource failedDataSource) {
        databaseLock.writeLock().lock();
        try {
            if (database == failedDataSource) {
                database = null;
            }
        } finally {
            databaseLock.writeLock().unlock();
        }
        failedDataSource.close();
    }
}
