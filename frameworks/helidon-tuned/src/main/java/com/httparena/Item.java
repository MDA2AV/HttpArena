package com.httparena;

import java.util.List;

import io.helidon.json.binding.Json;

@Json.Entity
record Item(long id,
            String name,
            String category,
            int price,
            int quantity,
            boolean active,
            List<String> tags,
            Rating rating) {
}
