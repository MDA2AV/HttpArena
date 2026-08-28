package httparena;

import com.fasterxml.jackson.annotation.JsonPropertyOrder;
import java.util.List;

@JsonPropertyOrder({"items", "count"})
public class OutList {
  public final List<OutItem> items;
  public final int count;

  public OutList(List<OutItem> items, int count) {
    this.items = items;
    this.count = count;
  }
}
