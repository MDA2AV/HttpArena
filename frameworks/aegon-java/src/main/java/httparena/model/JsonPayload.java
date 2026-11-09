package httparena.model;

import java.util.List;

public final class JsonPayload {
    public int count;
    public List<ProcessedItem> items;

    public JsonPayload() {}

    public JsonPayload(int count, List<ProcessedItem> items) {
        this.count = count;
        this.items = items;
    }
}

