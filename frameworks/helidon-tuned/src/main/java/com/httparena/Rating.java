package com.httparena;

import io.helidon.json.binding.Json;

@Json.Entity
record Rating(int score, long count) {
}
