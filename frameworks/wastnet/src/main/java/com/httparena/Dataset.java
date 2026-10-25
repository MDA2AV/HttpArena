package com.httparena;

import io.github.wycst.wast.json.JSON;

import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.List;

/** The 50-item dataset mounted at {@code /data/dataset.json}, read once at startup. */
final class Dataset {

    private static final List<JsonResult.Item> ITEMS = load();

    private Dataset() {
    }

    private static List<JsonResult.Item> load() {
        try {
            byte[] bytes = Files.readAllBytes(Paths.get("/data/dataset.json"));
            return JSON.parseArray(bytes, JsonResult.Item.class);
        } catch (Exception e) {
            throw new IllegalStateException("cannot read /data/dataset.json", e);
        }
    }

    static List<JsonResult.Item> items() {
        return ITEMS;
    }
}
