package com.httparena;

import io.github.wycst.wast.json.annotations.JsonTypeSetting;

import java.util.List;

/**
 * All JSON entities for the /json endpoint, defined in one class.
 * The {@code @JsonTypeSetting(enableJIT = true)} annotation lets wast generate a
 * dedicated serializer for each shape, which is what json-h2c actually measures.
 */
@JsonTypeSetting(enableJIT = true)
public class JsonResult {

    public List<Item> items;
    public int count;

    public JsonResult() {
    }

    public JsonResult(List<Item> items, int count) {
        this.items = items;
        this.count = count;
    }

    @JsonTypeSetting(enableJIT = true)
    public static class Item {

        public long id;
        public String name;
        public String category;
        public long price;
        public long quantity;
        public boolean active;
        public List<String> tags;
        public Rating rating;
        public long total;

        @JsonTypeSetting(enableJIT = true)
        public static class Rating {
            public long score;
            public long count;
        }
    }
}
