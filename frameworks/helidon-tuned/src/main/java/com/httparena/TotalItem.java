package com.httparena;

import java.util.List;

import io.helidon.json.binding.Json;

@Json.Entity
record TotalItem(long id,
                 String name,
                 String category,
                 int price,
                 int quantity,
                 boolean active,
                 List<String> tags,
                 Rating rating,
                 long total) {
    static TotalItem create(Item item, int multiplier) {
        long total = (long) item.price() * item.quantity() * multiplier;
        return new TotalItem(item.id(),
                             item.name(),
                             item.category(),
                             item.price(),
                             item.quantity(),
                             item.active(),
                             item.tags(),
                             item.rating(),
                             total);
    }
}
