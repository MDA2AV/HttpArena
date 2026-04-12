package com.httparena.spring.boot;

import com.fasterxml.jackson.annotation.JsonUnwrapped;

public record TotalItem(@JsonUnwrapped Item item, long total) {
    public static TotalItem fromItem(Item item, int m) {
        long total = (long) item.price() * item.quantity() * m;
        return new TotalItem(item, total);
    }
}
