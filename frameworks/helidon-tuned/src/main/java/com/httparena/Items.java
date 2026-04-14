package com.httparena;

import java.util.List;

import io.helidon.json.binding.Json;

@Json.Entity
record Items(List<Item> items, long count) {
}
