package httparena.model;

import java.util.List;

public final class ProcessedItem {
    public long id;
    public String name;
    public String category;
    public long price;
    public long quantity;
    public long total;
    public boolean active;
    public List<String> tags;
    public DatasetItem.Rating rating;

    public ProcessedItem() {}

    public ProcessedItem(DatasetItem d, long m) {
        this.id = d.id;
        this.name = d.name;
        this.category = d.category;
        this.price = d.price;
        this.quantity = d.quantity;
        this.total = d.price * d.quantity * m;
        this.active = d.active;
        this.tags = d.tags;
        this.rating = d.rating;
    }
}

