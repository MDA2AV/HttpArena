package com.httparena;

import java.util.List;

import io.helidon.json.binding.Json;

@Json.Entity
record TotalItems(List<TotalItem> items, long count) {
}
