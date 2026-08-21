package com.httparena;

import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;

import jakarta.annotation.PostConstruct;
import jakarta.enterprise.context.ApplicationScoped;

import java.net.URI;

/**
 * The Postgres pool the crud and fortunes resources share. BenchmarkResource
 * keeps its own for async-db; the two profiles never run together, so the pools
 * never coexist under load.
 */
@ApplicationScoped
public class Db {

    private HikariDataSource pool;

    public HikariDataSource pool() {
        return pool;
    }

    @PostConstruct
    void init() {
        String url = System.getenv("DATABASE_URL");
        if (url == null || url.isEmpty()) return;
        try {
            URI uri = new URI(url.replace("postgres://", "postgresql://"));
            String[] userInfo = uri.getUserInfo().split(":");
            int max = 64;
            String cap = System.getenv("DATABASE_MAX_CONN");
            if (cap != null) try { max = Math.max(1, Integer.parseInt(cap) / 4); }
                             catch (NumberFormatException ignored) {}

            HikariConfig config = new HikariConfig();
            config.setDriverClassName("org.postgresql.Driver");
            config.setJdbcUrl("jdbc:postgresql://" + uri.getHost() + ":"
                + (uri.getPort() > 0 ? uri.getPort() : 5432) + uri.getPath());
            config.setUsername(userInfo[0]);
            config.setPassword(userInfo.length > 1 ? userInfo[1] : "");
            config.setMaximumPoolSize(max);
            config.setMinimumIdle(Math.min(16, max));
            pool = new HikariDataSource(config);
        } catch (Exception ignored) {}
    }
}
