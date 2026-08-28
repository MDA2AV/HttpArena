package httparena;

import com.fasterxml.jackson.annotation.JsonPropertyOrder;

/** Field order is the wire order: id..rating then the computed total. */
@JsonPropertyOrder({"id", "name", "category", "price", "quantity", "active", "tags", "rating", "total"})
public class OutItem {
  public final long id;
  public final String name;
  public final String category;
  public final long price;
  public final long quantity;
  public final boolean active;
  public final String[] tags;
  public final Item.Rating rating;
  public final long total;

  public OutItem(Item d, long total) {
    this.id = d.id;
    this.name = d.name;
    this.category = d.category;
    this.price = d.price;
    this.quantity = d.quantity;
    this.active = d.active;
    this.tags = d.tags;
    this.rating = d.rating;
    this.total = total;
  }
}
