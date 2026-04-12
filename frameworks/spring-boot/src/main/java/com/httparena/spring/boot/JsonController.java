package com.httparena.spring.boot;

import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import tools.jackson.core.type.TypeReference;
import tools.jackson.databind.json.JsonMapper;

import java.nio.file.Paths;
import java.util.List;

@RestController
@RequestMapping("/json")
public class JsonController {

    private final List<Item> items;

    public JsonController(JsonMapper jsonMapper) {
        items = jsonMapper.readValue(Paths.get("/data/dataset.json"), new TypeReference<>() {});
    }

    @GetMapping(path = "/{count}", produces = MediaType.APPLICATION_JSON_VALUE)
    public TotalItems getTotalItems(@PathVariable int count, @RequestParam(defaultValue = "1") int m) {
        int n = Math.min(Math.max(count, 0), items.size());
        List<TotalItem> totalItems = items.subList(0, n).stream()
                .map(item -> TotalItem.fromItem(item, m))
                .toList();
        return new TotalItems(totalItems, totalItems.size());
    }

}
