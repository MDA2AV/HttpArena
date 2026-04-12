package com.httparena.spring.boot;

import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.boot.autoconfigure.condition.ConditionalOnProperty;
import org.springframework.http.MediaType;
import org.springframework.jdbc.core.simple.JdbcClient;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import tools.jackson.core.type.TypeReference;
import tools.jackson.databind.json.JsonMapper;

import java.util.List;

@RestController
@RequestMapping("/async-db")
@ConditionalOnProperty(name = "httparena.postgres-url")
public class AsyncDatabaseQueryController {
    private final JdbcClient jdbcClient;
    private final JsonMapper jsonMapper;

    public AsyncDatabaseQueryController(@Qualifier("postgresql") JdbcClient jdbcClient, final JsonMapper jsonMapper) {
        this.jdbcClient = jdbcClient;
        this.jsonMapper = jsonMapper;
    }

    @GetMapping(produces = MediaType.APPLICATION_JSON_VALUE)
    public Items getItems(
            @RequestParam(defaultValue = "10") int min,
            @RequestParam(defaultValue = "50") int max,
            @RequestParam(defaultValue = "50") int limit)
    {
        int clampedLimit = Math.min(Math.max(limit, 1), 50);
        try (var stream = jdbcClient.sql("""
                        SELECT id, name, category, price, quantity, active, tags, rating_score, rating_count
                        FROM items
                        WHERE price BETWEEN ? AND ?
                        LIMIT ?""")
                .param(1, min)
                .param(2, max)
                .param(3, clampedLimit)
                .query(ItemRow.class)
                .stream())
        {
            List<Item> items = stream
                    .map(this::toItem)
                    .toList();
            return new Items(items, items.size());
        }
    }

    private Item toItem(ItemRow itemRow) {
        return new Item(
                itemRow.id(),
                itemRow.name(),
                itemRow.category(),
                itemRow.price(),
                itemRow.quantity(),
                itemRow.active(),
                jsonMapper.readValue(itemRow.tags(), new TypeReference<>() {}),
                new Rating(itemRow.ratingScore(), itemRow.ratingCount())
        );
    }

    record ItemRow(int id, String name, String category, int price, int quantity, boolean active, String tags, int ratingScore, int ratingCount) {
    }
}
