package com.httparena;

import io.github.wycst.wastnet.http.annotation.Endpoint;
import io.github.wycst.wastnet.http.annotation.PathParam;
import io.github.wycst.wastnet.http.annotation.RequestParam;
import io.github.wycst.wastnet.http.annotation.RestController;

import java.util.ArrayList;
import java.util.List;

/** {@code GET /json/{count}?m={multiplier}} - serialized per request by the JSON converter. */
@RestController
public class JsonController {

    @Endpoint("/json/{count}")
    public Object json(@PathParam("count") int count,
                       @RequestParam(value = "m", required = false, defaultValue = "1") int m) {
        List<JsonResult.Item> source = Dataset.items();
        int n = count < 0 ? 0 : Math.min(count, source.size());

        List<JsonResult.Item> items = new ArrayList<JsonResult.Item>(n);
        for (int i = 0; i < n; i++) {
            JsonResult.Item src = source.get(i);
            JsonResult.Item item = new JsonResult.Item();
            item.id = src.id;
            item.name = src.name;
            item.category = src.category;
            item.price = src.price;
            item.quantity = src.quantity;
            item.active = src.active;
            item.tags = src.tags;
            item.rating = src.rating;
            item.total = src.price * src.quantity * (long) m;
            items.add(item);
        }

        return new JsonResult(items, n);
    }
}
